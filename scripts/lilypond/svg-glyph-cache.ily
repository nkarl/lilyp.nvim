% Lylip's per-compilation native SVG glyph cache. Compatibility checks run in
% the actual compiler, before the score; unsupported runtimes engrave normally.
% This uses a private LilyPond 2.26.0 interface. Keep the version gate exact.
#(when (and (equal? (ly:version) '(2 26 0))
            (eq? (ly:get-option 'backend) 'svg))
   (catch #t
     (lambda ()
       (resolve-interface '(lily output-svg))
       (let* ((backend (resolve-module '(lily output-svg)))
              (binding (module-variable backend 'cache-font))
              (original (and binding (variable-bound? binding)
                             (variable-ref binding))))
         (when (and (procedure? original)
                    (equal? (procedure-minimum-arity original) '(3 0 #f))
                    (not (procedure-property original 'lilyp-svg-glyph-cache)))
           (let* ((cache (make-hash-table))
                  (entries 0)
                  (wrapper
                    (lambda (font size glyph)
                      ; Compound glyph strings update offsets/advances. Only
                      ; the pure single-glyph branch is eligible for caching.
                      (if (and (string? font) (number? size) (string? glyph))
                          (let* ((key (list font size glyph))
                                 (cached (hash-ref cache key)))
                            (or cached
                                (let ((path (original font size glyph)))
                                  ; Keep successful strings, including empty
                                  ; paths. Never swallow compiler exceptions.
                                  (when (and (string? path) (< entries 4096))
                                    (hash-set! cache key path)
                                    (set! entries (+ entries 1)))
                                  path)))
                          (original font size glyph)))))
             (set-procedure-property! wrapper 'lilyp-svg-glyph-cache #t)
             (module-set! backend 'cache-font wrapper)))))
     ; Catch installation/introspection failures only. Calls to the original
     ; renderer occur later, outside this handler, with normal error semantics.
     (lambda args #f)))
