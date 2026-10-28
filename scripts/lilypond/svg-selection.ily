% Compiler facts for read-only viewer selection. Timing-context identity keeps
% separate scores and independent polymetric contexts apart. No music is changed.
#(define lilyp-timings (make-hash-table))
#(define (lilyp-note-metadata context)
   (make-engraver
    (acknowledgers
     ((note-head-interface engraver grob source)
      (let* ((timing (ly:context-property-where-defined context 'currentBarNumber))
             (score (ly:context-find context 'Score))
             (event (ly:grob-property grob 'cause))
             (pitch (and (ly:stream-event? event) (ly:event-property event 'pitch)))
             (number (and timing (ly:context-property timing 'currentBarNumber)))
             (position (and timing (ly:context-property timing 'measurePosition)))
             (length (and timing (ly:context-property timing 'measureLength))))
        (when (and score (integer? number) (ly:context-property timing 'timing #t) (ly:moment? position) (and (rational? length) (> length 0)) (ly:pitch? pitch))
          (let* ((id (or (hashq-ref lilyp-timings timing)
                         (let ((next (+ 1 (hash-count (const #t) lilyp-timings))))
                           (hashq-set! lilyp-timings timing next) next)))
                 ; A pickup has negative measurePosition. Normalize it into
                 ; the enclosing full bar before subtracting, so the pickup
                 ; cannot collide with the following complete measure.
                 (offset (if (< (ly:moment-main-numerator position) 0)
                             (ly:moment-add position (ly:make-moment length))
                             position))
                 (start (ly:moment-sub (ly:context-current-moment context) offset)))
            (ly:grob-set-property! grob 'output-attributes
             (append (ly:grob-property grob 'output-attributes '())
              `((data-measure . ,(format #f "~a:~a:~a:~a" id number (format #f "~a/~a" (ly:moment-main-numerator start) (ly:moment-main-denominator start)) length))
                (data-measure-number . ,(number->string number))
                (data-pitch . ,(number->string (+ 60 (ly:pitch-semitones pitch))))))))))))))
\layout { \context { \Voice \consists #lilyp-note-metadata } }
