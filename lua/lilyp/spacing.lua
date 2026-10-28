-- Relationship catalog shared by semantics, UI, and LilyPond recipes.
return {
  {id='lyric_staff',label='Lyrics ↔ staff',property='VerticalAxisGroup.nonstaff-relatedstaff-spacing',context='Lyrics',scopes={'global','section'}},
  {id='row',label='Lyric rows',property='VerticalAxisGroup.nonstaff-nonstaff-spacing',context='Lyrics',preferred='row_spacing',scopes={'global','section'}},
  {id='staff_group',label='Grouped staves',property='StaffGrouper.staff-staff-spacing',context='Score',scopes={'global','section'}},
  {id='system',label='Between systems',property='system-system-spacing',paper=true,scopes={'global'}},
}
