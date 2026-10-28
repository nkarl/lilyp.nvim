-- Parse and serialize passive generated SVG using the bundled namespace-aware
-- XML parser. Unknown/active elements are omitted only from the viewing copy.
local M={}
local SVG='http://www.w3.org/2000/svg'
local XLINK='http://www.w3.org/1999/xlink'
local XML='http://www.w3.org/XML/1998/namespace'
local allowed={svg=true,g=true,defs=true,path=true,rect=true,line=true,polygon=true,polyline=true,
  circle=true,ellipse=true,text=true,tspan=true,a=true,use=true,style=true,clipPath=true}
local metadata_names={['data-measure']=true,['data-measure-number']=true,['data-pitch']=true}
local function fraction(value)
  if type(value)~='string' then return nil end
  if value:match('^%-?%d+$') then return tonumber(value) end
  local numerator,denominator=value:match('^(%-?%d+)/(%d+)$')
  if numerator and tonumber(denominator)>0 then return tonumber(numerator)/tonumber(denominator) end
end
local function note_metadata(meta)
  local timing,bar,start,length=(meta['data-measure'] or ''):match('^(%d+):(%-?%d+):(%-?%d+/%d+):(%d+/?%d*)$')
  return timing and tonumber(timing)>0 and bar==meta['data-measure-number'] and fraction(start)
    and fraction(length) and fraction(length)>0 and fraction(meta['data-pitch'])
end
local function escape(value)
  return value:gsub('&','&amp;'):gsub('<','&lt;'):gsub('>','&gt;'):gsub('"','&quot;'):gsub("'",'&apos;')
end
function M.index(pages)
  local rendered,entries,occurrences={},{},{}
  for page_number,raw in ipairs(pages) do
    assert(not raw:find('<!DOCTYPE',1,true) and not raw:find('<!ENTITY',1,true),'SVG document declarations are unsupported')
    local stack,root={},nil
    local parser=require('lilyp.vendor.slaxml'):parser({
      startElement=function(name,namespace)
        local parent=stack[#stack]
        if not parent then assert(not root and name=='svg' and namespace==SVG,'Compiler output is not one SVG document') end
        local node={name=name,namespace=namespace,attrs={},metadata={},kids={},keep=namespace==SVG and allowed[name] and (not parent or parent.keep)}
        if parent then parent.kids[#parent.kids+1]=node else root=node end
        stack[#stack+1]=node
      end,
      attribute=function(name,value,namespace,prefix)
        local node=stack[#stack]
        if name=='href' and (not namespace or namespace==XLINK) then
          node.link=require('lilyp.source_index').parse_uri(value)
          if value:sub(1,1)=='#' then node.attrs[#node.attrs+1]={namespace==XLINK and 'xlink:href' or 'href',value} end
        elseif not namespace and metadata_names[name] then
          node.metadata[name]=value
        elseif name~='xmlns' and not name:match('^xmlns:') and not name:lower():match('^on')
          and not name:match('^data%-') and (not namespace or namespace==XML) then
          node.attrs[#node.attrs+1]={namespace==XML and 'xml:'..name or name,value}
        end
      end,
      text=function(value)
        local node=stack[#stack]
        if node then node.kids[#node.kids+1]=value else assert(not value:find('%S'),'Text outside SVG') end
      end,
      closeElement=function(name,namespace)
        local node=table.remove(stack)
        assert(node and node.name==name and node.namespace==namespace,'Mismatched SVG element')
      end,
    })
    parser:parse(raw)
    assert(root and #stack==0,'Incomplete SVG')
    local output={}
    local function serialize(node)
      if type(node)=='string' then output[#output+1]=escape(node);return end
      if not node.keep then return end
      output[#output+1]='<'..node.name
      if node==root then output[#output+1]=' xmlns="'..SVG..'" xmlns:xlink="'..XLINK..'"' end
      -- Accept the complete compiler notehead tuple only; all other data-* stays stripped.
      local meta=node.metadata
      if node.name=='g' and note_metadata(meta) then
        for _,name in ipairs({'data-measure','data-measure-number','data-pitch'}) do
          output[#output+1]=' '..name..'="'..escape(meta[name])..'"'
        end
      end
      for _,attr in ipairs(node.attrs) do output[#output+1]=' '..attr[1]..'="'..escape(attr[2])..'"' end
      if node.link then
        local entry=node.link
        entry.page,entry.key=page_number-1,#entries
        entries[#entries+1]=entry
        local identity=vim.json.encode({entry.source,entry.line,entry.char})
        occurrences[identity]=(occurrences[identity] or 0)+1
        local anchor=vim.json.encode({entry.source,entry.line,entry.char,occurrences[identity]})
        output[#output+1]=' data-note="'..entry.key..'" data-source="'..escape(anchor)..'"'
      end
      output[#output+1]='>'
      for _,child in ipairs(node.kids) do serialize(child) end
      output[#output+1]='</'..node.name..'>'
    end
    serialize(root);rendered[#rendered+1]=table.concat(output)
  end
  return rendered,entries
end
return M
