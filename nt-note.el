;;; nt-note.el --- Notation Overlays -*- lexical-binding: t; -*-

;; Copyright © 2019 Eric Kaschalk <ekaschalk@gmail.com>

;;; Commentary:

;; Notation overlay management, instantiation, etc.

;; `hl-todo' users, remove highlighting of NOTE in docstrings with:
;;   (setq hl-todo-keyword-faces (--remove (s-equals? (car it) "NOTE") hl-todo-keyword-faces))

;;; Code:
;;;; Requires

(require 'nt-base)

(require 'nt-ov)


;;; Configuration

(defface nt-note--face
  `((t (:height 1)))
  "Face applied to notes.")

;;; Overlays

(defun nt-notes--present? (&optional start end)
  "Are notes present in START and END, defaulting to `match-data'? Get them."
  (let ((start (or start (match-beginning 1)))
        (end   (or end (match-end 1))))
    (and start end
         (reverse (-filter #'nt-ov--note?
                           (overlays-in start end))))))

(defun nt-note--at (pos)
  "Get note at POS."
  (-first-item (nt-notes--present? pos (1+ pos))))

(defun nt-note--at-point ()
  "Get note at point."
  (nt-note--at (point)))

(defun nt-notes--at (line)
  "Return all notes on LINE."
  (apply #'nt-notes--present? (nt-base--line-bounds line)))

(defun nt-notes--in (start-line end-line)
  "Return all notes in [START-LINE END-LINE)."
  (apply #'nt-notes--present? (nt-base--lines-bounds start-line end-line)))

(defun nt-note--delete (note)
  "Delete NOTE."
  (delq note nt-note-list)
  (delete-overlay note))

(defun nt-note--decompose-hook (note post-modification? start end &optional _)
  "Decompose NOTE upon modification as a modification-hook."
  (when post-modification?
    ;; TODO Below will be replaced with the new deletion implementation that
    ;; doesn't require calling masks-for.
    (nt--remove-note-from-masks note)
    (nt-note--delete note)))

;;; Transforms
;;;; Overlay-Based

(defun nt-note->width (note)
  "Wrapper to access width of NOTE."
  (overlay-get note 'nt-width))

(defun nt-note->bound (note)
  "Return NOTE's bound."
  (overlay-get note 'nt-bound))

(defun nt-note->replacement (note)
  "Return NOTE's replacement."
  (overlay-get note 'display))

(defun nt-notes->width (notes)
  "Sum widths of NOTES."
  (->> notes (-map #'nt-note->width) -sum))

(defun nt-note->string (note)
  "Return NOTE's string."
  (apply #'buffer-substring-no-properties (nt-ov->region note)))

;;;; Misc

(defun nt-note->indent (note)
  "Return indent of line containing NOTE."
  (-> note nt-ov->line nt-base--indent-at))

;;; NEW

(defun nt-notes<-region (start end)
  "Return notes in region START and END."
  (nt-notes--present? start end))

(defun nt-notes--sort (notes)
  "Return NOTES sorted according to start position."
  (-sort (-on #'< #'overlay-start)
         notes))

(defun nt--delete-region (start end)
  "Delete NOTES managed in START and END and refresh contributed to masks."
  (let* ((notes (nt-notes<-region start end))
         (roots (nt-notes->roots notes))
         (bounds (-map nt-note->bound roots)))
    (-each notes #'nt-note--delete)
    (-each notes #'nt-mask--refresh-region)))

(defun nt-notes->roots-1 (notes root roots)
  "Internal, see `nt-notes->roots'."
  (-if-let* (((_ root-end)
              (nt-note->bound root))
             (next
              (-drop-while (-compose (-partial #'> root-end)
                                     #'car
                                     #'nt-note->bound)
                           notes)))
      (nt-notes->roots next (cons root roots))
    (cons root roots)))

(defun nt-notes->roots (notes &optional roots)
  "Return roots, the set of largest non-overlapping intervals, of NOTES.

Steps:
1. Traverse _sorted_ NOTES by start position.
2. First occurring note with start greater than head note's end is a root.
3. Recurse fixing each root at head until NOTES is exhausted."
  (-let (((root . rest) notes))
    (cond (rest (nt-notes->roots-1 rest root roots))
          (root (cons root roots))
          (roots))))

;;; Init

(defun nt-note--init-ov (ov string replacement)
  "Put note text properties into OV."
  (-doto ov
    (overlay-put 'nt?      t)
    (overlay-put 'nt-note? t)
    (overlay-put 'nt-width (nt-base--s-diff string replacement))

    (overlay-put 'display replacement)
    (overlay-put 'modification-hooks '(nt-note--decompose-hook))))

(defun nt-note--init (string replacement &optional start end)
  "Build note overlay, defaulting to `match-data' for START and END."
  (setq start (or start (match-beginning 1)))
  (setq end   (or end   (match-end 1)))

  (unless (and start end)
    (error "Initiatializing note without match-data set."))

  (let* ((ov   (make-overlay start end))
         (note (nt-note--init-ov ov string replacement)))
    (push note nt-note-list)
    (nt--add-note-to-masks note)

    ;; New tree stuff

    (overlay-put note 'nt-bound (funcall (symbol-value #'nt-bound-fn) note))

    ;; end tree stuff

    note))

;;; Font Locks
;;;; Spec Handling

(defun nt-note--validate (string replacement)
  "Throw error on egregious inputs."
  (cond
   ((or (s-contains? "\n" string)
        (s-contains? "\n" replacement))
    (error "Newlines anywhere in spec components cause ambiguity."))

   ((= 0
       (length replacement))
    (error "Zero-width replacements can be done natively with 'invisible."))

   ((> (length replacement)
       (length string))
    (error "Indentation expansions not supported yet, but I would like to."))))

(defun nt-note--string->rx (string)
  "Convert string to an expected nt-note RX."
  (rx-to-string `(group ,string)
                'no-shy-group))

(defun nt-note--make (string replacement &optional rx)
  "Create spec plist for STRING to REPLACEMENT optionally with custom RX.

Without a RX given, default to matching entire STRING.
The RX, if given, should set the first group for the match to replace."
  (nt-note--validate string replacement)

  `(:string
    ,string
    :rx          ,(or rx (nt-note--string->rx string))
    :replacement ,replacement))

(defun nt-notes--make (specs)
  "Apply `nt-note--make' to each SPEC."
  (-map (-applify #'nt-note--make) specs))

;;;; Keyword Construction

(defun nt-note--kwd-match (string replacement)
  "The form for FACENAME in font-lock-keyword's MATCH-HIGHNOTEHT."
  (unless (nt-notes--present?)
    (nt-note--init string replacement)))

(defun nt-note--kwd-build (spec)
  "Compose the font-lock-keyword for SPEC in `nt-notes'."
  (-let (((&plist :string string
                  :replacement replacement
                  :rx rx)
          spec))
    `(,rx (0 (prog1 `,(and nt-normalize-height?
                           'nt-note--face)
               (nt-note--kwd-match ,string ,replacement))))))

(defun nt-note--kwds-add ()
  "Build kwds from `nt-notes' and add to `font-lock-keywords'."
  (->> nt-notes
     (-map #'nt-note--kwd-build)
     (font-lock-add-keywords nil)))

;;; Provide

(provide 'nt-note)

;;; nt-note.el ends here
