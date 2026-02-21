;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;
;; MODULE      : init-ai.scm
;; DESCRIPTION : AI Assistant plugin with Claude and Ollama integration
;; COPYRIGHT   : (C) 2025  Mogan STEM authors
;;
;; This software falls under the GNU general public license version 3 or later.
;; It comes WITHOUT ANY WARRANTY WHATSOEVER. For details, see the file LICENSE
;; in the root directory or <http://www.gnu.org/licenses/gpl-3.0.html>.
;;
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(plugin-configure ai
  (:require #t)
  (:session "AI Assistant"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Configuration
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Ollama settings
(define ai-model "qwen2.5:7b")
(define ai-ollama-url "http://localhost:11434/api/generate")

;; Claude API settings
(define ai-claude-api-key "")  ;; Set your API key here: sk-ant-api03-...
(define ai-claude-url "https://api.anthropic.com/v1/messages")
(define ai-claude-model "claude-sonnet-4-20250514")
(define ai-always-use-context #f)
(define ai-loaded-pdf-path "")
(define ai-python-helper (string-append (getenv "HOME") "/.TeXmacs/plugins/ai/bin/ai-helper.py"))
(define ai-python-helper-tmp "/tmp/mogan-ai-helper.py")
(define ai-helper-ready #f)

;; Common settings
(define ai-request-timeout 120)
(define ai-max-retries 3)
(define ai-initial-delay-ms 500)
(define ai-conversation-history '())
(define ai-max-history 2)

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Utilities
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (json-escape-string s)
  (let ((result s))
    ;; Remove control characters (ASCII 0-31 except tab, newline, carriage return)
    (set! result (string-replace result "\x01" ""))
    (set! result (string-replace result "\x02" ""))
    (set! result (string-replace result "\x03" ""))
    (set! result (string-replace result "\x11" ""))  ;; Common culprit
    (set! result (string-replace result "\x12" ""))
    (set! result (string-replace result "\x13" ""))
    (set! result (string-replace result "\x14" ""))
    ;; Standard escaping
    (set! result (string-replace result "\\" "\\\\"))
    (set! result (string-replace result "\"" "\\\""))
    (set! result (string-replace result "\n" "\\n"))
    (set! result (string-replace result "\r" "\\r"))
    (set! result (string-replace result "\t" "\\t"))
    result))

(define (shell-escape s)
  (string-replace s "'" "'\\''"))

(define (ai-strip-markdown text)
  (let* ((result text)
         (result (string-replace result "**" "")))
    result))

(define (ai-escape-latex text)
  ;; Escape special LaTeX characters (unused - Claude formats in LaTeX)
  (let ((result text))
    (set! result (string-replace result "\\" "\\textbackslash{}"))
    (set! result (string-replace result "#" "\\#"))
    (set! result (string-replace result "%" "\\%"))
    (set! result (string-replace result "&" "\\&"))
    (set! result (string-replace result "_" "\\_"))
    (set! result (string-replace result "^" "\\textasciicircum{}"))
    (set! result (string-replace result "~" "\\textasciitilde{}"))
    result))

(define (ai-sleep-ms milliseconds)
  (system (string-append "sleep " (number->string (/ milliseconds 1000.0)))))

(define (unescape-json-string s)
  (let ((result s))
    (set! result (string-replace result "\\\\" "\x00BSLASH\x00"))
    (set! result (string-replace result "\\n" "\n"))
    (set! result (string-replace result "\\r" "\r"))
    (set! result (string-replace result "\\t" "\t"))
    (set! result (string-replace result "\\\"" "\""))
    (set! result (string-replace result "\x00BSLASH\x00" "\\"))
    (set! result (string-replace result "\\u003c" "<"))
    (set! result (string-replace result "\\u003e" ">"))
    (set! result (string-replace result "\\u003C" "<"))
    (set! result (string-replace result "\\u003E" ">"))
    result))

(define (parse-json-simple json-str)
  ;; Simple JSON parser - extracts common fields
  ;; Returns association list: ((key . value) ...)
  (let ((result '()))
    ;; Check for success: true
    (when (string-search-forwards "\"success\": true" 0 json-str)
      (set! result (cons (cons "success" #t) result)))
    (when (string-search-forwards "\"success\":true" 0 json-str)
      (set! result (cons (cons "success" #t) result)))
    ;; Extract path field
    (let ((path-pos (string-search-forwards "\"path\":" 0 json-str)))
      (when (>= path-pos 0)
        (let* ((after (substring json-str (+ path-pos 8) (string-length json-str)))
               (end (string-search-forwards "\"" 0 after)))
          (when (>= end 0)
            (set! result (cons (cons "path" (substring after 0 end)) result))))))
    ;; Extract answer field
    (let ((answer-pos (string-search-forwards "\"answer\":\"" 0 json-str)))
      (when (>= answer-pos 0)
        (let* ((start (+ answer-pos 10))
               (after (substring json-str start (string-length json-str)))
               (end (string-search-forwards "\"}" 0 after)))
          (when (>= end 0)
            (set! result (cons (cons "answer" (unescape-json-string (substring after 0 end))) result))))))
    ;; Extract error field
    (let ((error-pos (string-search-forwards "\"error\":\"" 0 json-str)))
      (when (>= error-pos 0)
        (let* ((start (+ error-pos 9))
               (after (substring json-str start (string-length json-str)))
               (end (string-search-forwards "\"}" 0 after)))
          (when (>= end 0)
            (set! result (cons (cons "error" (substring after 0 end)) result))))))
    result))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Document context extraction
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (ai-tree->text tree)
  (cond
   ((string? tree) tree)
   ((not (pair? tree)) "")
   (else
    (let ((tag (car tree)) (args (cdr tree)))
      (cond
       ((eq? tag 'math) (string-append "$" (ai-trees->text args) "$"))
       ((eq? tag 'equation) (string-append "$$" (ai-trees->text args) "$$"))
       ((eq? tag 'frac) (string-append "\\frac{" (ai-tree->text (car args)) "}{" (ai-tree->text (cadr args)) "}"))
       ((eq? tag 'rsup) (string-append "^{" (ai-trees->text args) "}"))
       ((eq? tag 'rsub) (string-append "_{" (ai-trees->text args) "}"))
       ((eq? tag 'sqrt) (string-append "\\sqrt{" (ai-trees->text args) "}"))
       ((eq? tag 'alpha) "\\alpha") ((eq? tag 'beta) "\\beta") ((eq? tag 'gamma) "\\gamma")
       ((eq? tag 'delta) "\\delta") ((eq? tag 'pi) "\\pi") ((eq? tag 'sigma) "\\sigma")
       ((eq? tag 'theta) "\\theta") ((eq? tag 'lambda) "\\lambda") ((eq? tag 'omega) "\\omega")
       ((memq tag '(document para concat with)) (ai-trees->text args))
       (else (ai-trees->text args)))))))

(define (ai-trees->text trees)
  (let ((texts (map ai-tree->text trees)))
    (apply string-append
           (let loop ((lst texts) (result '()))
             (if (null? lst) (reverse result)
                 (let ((t (car lst)))
                   (if (> (string-length t) 0)
                       (loop (cdr lst) (cons " " (cons t result)))
                       (loop (cdr lst) result))))))))

(define (ai-get-selection)
  (if (selection-active-any?)
      (let ((sel (selection-tree)))
        (if sel (ai-tree->text (tree->stree sel)) ""))
      ""))

(define (ai-get-cursor-paragraph)
  (let ((t (cursor-tree)))
    (if t (ai-tree->text (tree->stree t)) "")))

(define (ai-extract-math tree)
  (cond
   ((string? tree) '())
   ((not (pair? tree)) '())
   (else
    (let ((tag (car tree)) (args (cdr tree)))
      (if (memq tag '(math equation equation*))
          (list (ai-tree->text tree))
          (apply append (map ai-extract-math args)))))))

(define (ai-get-document-context)
  (let* ((selection (ai-get-selection))
         (doc-tree (buffer-tree))
         (doc-stree (if doc-tree (tree->stree doc-tree) '()))
         (full-text (if (pair? doc-stree) (ai-tree->text doc-stree) ""))
         (all-math (if (pair? doc-stree) (ai-extract-math doc-stree) '())))
    (string-append
     (if (> (string-length selection) 0)
         (string-append "[Selected text: " selection "]\n\n")
         "")
     (if (> (string-length full-text) 0)
         (string-append "[Document content:\n" full-text "\n]\n\n")
         "")
     (if (> (length all-math) 0)
         (string-append "[All formulas in document:\n"
                        (apply string-append (map (lambda (m) (string-append "  " m "\n")) all-math))
                        "]\n")
         ""))))

(define (ai-build-context-prompt question)
  (let ((context (ai-get-document-context)))
    (if (> (string-length context) 0)
        (string-append "You are helping with a scientific document. Context:\n\n" context "\nQuestion: " question "\n\nAnswer:")
        question)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Ollama API
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define ai-request-file "/tmp/mogan-ai-request.json")
(define ai-response-file "/tmp/mogan-ai-response.json")
(define ai-script-file "/tmp/mogan-ai-curl.sh")

(define (build-ollama-request-body question)
  (string-append "{\"model\":\"" ai-model "\",\"prompt\":\"" (json-escape-string question) "\",\"stream\":false}"))

(define (build-curl-command question)
  (let ((body (build-ollama-request-body question)))
    (string-save body (unix->url ai-request-file))
    (string-save
     (string-append "#!/bin/bash\n/usr/bin/curl -s --max-time " (number->string ai-request-timeout)
                    " -o " ai-response-file " -X POST " ai-ollama-url
                    " -H 'Content-Type: application/json' -d @" ai-request-file "\n")
     (unix->url ai-script-file))
    (string-append "/bin/bash " ai-script-file)))

(define (extract-ollama-response body)
  (let* ((marker "\"response\":\"")
         (start-pos (string-search-forwards marker 0 body)))
    (if (< start-pos 0) #f
        (let* ((text-start (+ start-pos (string-length marker)))
               (after-marker (substring body text-start (string-length body)))
               (end-pos (string-search-forwards "\",\"done\":" 0 after-marker)))
          (if (>= end-pos 0)
              (unescape-json-string (substring after-marker 0 end-pos))
              (let ((end-pos2 (string-search-forwards "\"," 0 after-marker)))
                (if (>= end-pos2 0) (unescape-json-string (substring after-marker 0 end-pos2)) #f)))))))

(define (ai-attempt-request cmd)
  (system (string-append "rm -f " ai-response-file))
  (eval-system cmd)
  (let retry-read ((attempt 1))
    (if (> attempt 10)
        #f
        (begin
          (system "sleep 0.2")
          (let ((response (var-eval-system (string-append "cat " ai-response-file))))
            (if (and response (> (string-length response) 0))
                (extract-ollama-response response)
                (retry-read (+ attempt 1))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Claude API
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define ai-claude-request-file "/tmp/mogan-claude-request.json")
(define ai-claude-response-file "/tmp/mogan-claude-response.json")
(define ai-claude-script-file "/tmp/mogan-claude-curl.sh")

(define (build-claude-request-body question)
  (let ((escaped (json-escape-string question)))
    (string-save question (unix->url "/tmp/original-text.txt"))
    (string-save escaped (unix->url "/tmp/escaped-text.txt"))
    (string-append "{\"model\":\"" ai-claude-model
                   "\",\"max_tokens\":4096"
                   ",\"system\":\"You are writing for a LaTeX document. CRITICAL RULES: 1) Use ONLY LaTeX formatting, NEVER markdown. 2) For emphasis use \\\\textbf{text} NOT **text**. 3) For math: $expression$ (inline) or $$expression$$ (display). 4) Use \\\\sqrt{}, \\\\frac{}{}, ^{}, _{}. 5) NEVER use asterisks ** for bold - they will appear as literal asterisks in the output.\""
                   ",\"messages\":[{\"role\":\"user\",\"content\":\"" escaped "\"}]}")))

(define (build-claude-curl-command question)
  (let ((body (build-claude-request-body question)))
    (string-save body (unix->url ai-claude-request-file))
    (string-save
     (string-append "#!/bin/bash\n/usr/bin/curl -s --max-time 60"
                    " -o " ai-claude-response-file
                    " -X POST " ai-claude-url
                    " -H 'Content-Type: application/json'"
                    " -H 'x-api-key: " ai-claude-api-key "'"
                    " -H 'anthropic-version: 2023-06-01'"
                    " -d @" ai-claude-request-file "\n")
     (unix->url ai-claude-script-file))
    (string-append "/bin/bash " ai-claude-script-file)))

(define (extract-claude-response body)
  ;; Claude response: {"content":[{"type":"text","text":"..."}],...}
  (let* ((marker "\"text\":\"")
         (start-pos (string-search-forwards marker 0 body)))
    (if (< start-pos 0) #f
        (let* ((text-start (+ start-pos (string-length marker)))
               (after-marker (substring body text-start (string-length body)))
               (end-pos (string-search-forwards "\"}]" 0 after-marker)))
          (if (>= end-pos 0)
              (unescape-json-string (substring after-marker 0 end-pos))
              (let ((end-pos2 (string-search-forwards "\"}" 0 after-marker)))
                (if (>= end-pos2 0)
                    (unescape-json-string (substring after-marker 0 end-pos2))
                    #f)))))))

(define (ai-attempt-claude-request cmd)
  (eval-system cmd)
  (let retry-read ((attempt 1))
    (if (> attempt 10)
        #f
        (begin
          (system "sleep 0.2")
          (let ((response (var-eval-system (string-append "cat " ai-claude-response-file))))
            (if (and response (> (string-length response) 0))
                (extract-claude-response response)
                (retry-read (+ attempt 1))))))))

(define (ai-call-claude question)
  (if (or (not ai-claude-api-key) (string=? ai-claude-api-key ""))
      (begin
        (set-message "Error: Claude API key not set (edit init-ai.scm line 26)" "AI")
        #f)
      (begin
        (set-message "Waiting for Claude response..." "AI")
        (system (string-append "rm -f " ai-claude-response-file))
        (let ((cmd (build-claude-curl-command question)))
          (let retry-loop ((attempt 1) (delay-ms ai-initial-delay-ms))
            (let ((content (ai-attempt-claude-request cmd)))
              (cond (content content)
                    ((< attempt ai-max-retries)
                     (ai-sleep-ms delay-ms)
                     (retry-loop (+ attempt 1) (* delay-ms 2)))
                    (else #f))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Ollama auto-start
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define ai-ollama-check-file "/tmp/mogan-ai-ollama-check.txt")
(define ai-ollama-check-script "/tmp/mogan-ai-ollama-check.sh")

(define (ai-ollama-running?)
  (string-save
   (string-append "#!/bin/bash\nrm -f " ai-ollama-check-file "\n/usr/bin/curl -s -o " ai-ollama-check-file
                  " --connect-timeout 2 http://localhost:11434/api/tags 2>/dev/null\n")
   (unix->url ai-ollama-check-script))
  (eval-system (string-append "/bin/bash " ai-ollama-check-script))
  (let ((result (string-load (unix->url ai-ollama-check-file))))
    (and result (> (string-length result) 0))))

(define (ai-start-ollama)
  (system "ollama serve > /dev/null 2>&1 &")
  (let wait-loop ((attempts 0))
    (if (>= attempts 10) #f
        (begin (ai-sleep-ms 500)
               (if (ai-ollama-running?) #t (wait-loop (+ attempts 1)))))))

(define (ai-ensure-ollama)
  (if (ai-ollama-running?) #t (ai-start-ollama)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Conversation history
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (ai-add-to-history question answer)
  (set! ai-conversation-history
        (let ((new-history (cons (cons question answer) ai-conversation-history)))
          (if (> (length new-history) ai-max-history) (list-head new-history ai-max-history) new-history))))

(define (ai-clear-history)
  (set! ai-conversation-history '()))

(define (ai-format-history-for-prompt)
  (if (null? ai-conversation-history) ""
      (string-append "Previous conversation:\n"
                     (apply string-append
                            (map (lambda (pair) (string-append "User: " (car pair) "\nAI: " (cdr pair) "\n\n"))
                                 (reverse ai-conversation-history)))
                     "---\n")))

(define (ai-build-prompt-with-history question)
  (let ((history-context (ai-format-history-for-prompt)))
    (if (> (string-length history-context) 0)
        (string-append history-context "User: " question "\nAI:")
        question)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Main Ollama request function
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (ai-send-request-raw question)
  (if (not (ai-ensure-ollama)) #f
      (begin
        (set-message "Waiting for Ollama response..." "AI")
        (let ((cmd (build-curl-command question)))
          (let retry-loop ((attempt 1) (delay-ms ai-initial-delay-ms))
            (let ((content (ai-attempt-request cmd)))
              (cond (content content)
                    ((< attempt ai-max-retries)
                     (ai-sleep-ms delay-ms)
                     (retry-loop (+ attempt 1) (* delay-ms 2)))
                    (else #f))))))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Scratch pad - reuses single file /tmp/AI-Scratch.tex
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define ai-scratch-file "/tmp/AI-Scratch.tex")
(define ai-scratch-url (unix->url ai-scratch-file))

(define (ai-write-scratch question answer)
  (when (buffer-exists? ai-scratch-url)
    (buffer-pretend-saved ai-scratch-url)
    (buffer-close ai-scratch-url))
  (system (string-append "rm -f " ai-scratch-file))
  (string-save
   (string-append
    "\\documentclass{article}\n"
    "\\usepackage{amsmath}\n"
    "\\begin{document}\n\n"
    "\\textbf{Question:} " question "\n\n"
    "\\textbf{Answer:}\n\n"
    answer "\n\n"
    "\\end{document}\n")
   ai-scratch-url)
  (load-buffer ai-scratch-file))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User-facing functions - Claude
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (ai-ask-claude question)
  (set-message "Asking Claude AI..." "AI")
  (let* ((full-prompt (ai-build-prompt-with-history question))
         (content (ai-call-claude full-prompt)))
    (if content
        (begin
          (ai-add-to-history question content)
          (ai-write-scratch question content))
        (set-message "Error: No response from Claude" "AI"))))

(define (ai-ask-claude-with-context question)
  (string-save "CONTEXT CALLED" (unix->url "/tmp/claude-context-debug.txt"))
  (set-message "Asking Claude AI (with context)..." "AI")
  (let* ((context-prompt (ai-build-context-prompt question)))
    (string-save context-prompt (unix->url "/tmp/claude-context-prompt.txt"))
    (let* ((full-prompt (ai-build-prompt-with-history context-prompt))
           (content (ai-call-claude full-prompt)))
      (string-save (if content "GOT CONTENT" "NO CONTENT") (unix->url "/tmp/claude-context-result.txt"))
      (if content
          (begin
            (ai-add-to-history question content)
            (ai-write-scratch question content))
          (set-message "Error: No response from Claude" "AI")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; User-facing functions - Ollama
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (ai-ask question)
  (if (not (ai-ensure-ollama))
      (set-message "Error: Could not start Ollama" "AI")
      (let* ((full-prompt (ai-build-prompt-with-history question))
             (content (ai-send-request-raw full-prompt)))
        (if content
            (begin
              (ai-add-to-history question content)
              (ai-write-scratch question (ai-strip-markdown content)))
            (set-message "Error: No response from Ollama" "AI")))))

(define (ai-ask-with-context question)
  (if (not (ai-ensure-ollama))
      (set-message "Error: Could not start Ollama" "AI")
      (let* ((context-prompt (ai-build-context-prompt question))
             (full-prompt (ai-build-prompt-with-history context-prompt))
             (content (ai-send-request-raw full-prompt)))
        (if content
            (begin (ai-add-to-history question content)
                   (ai-write-scratch question (ai-strip-markdown content)))
            (set-message "Error: No response from Ollama" "AI")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Help with Mogan
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define ai-web-search-file "/tmp/mogan-ai-web-search.txt")

(define (ai-search-web query)
  (let ((search-script (string-append "#!/bin/bash\nrm -f " ai-web-search-file
                                       "\n/usr/bin/curl -s -L --max-time 10 'https://www.texmacs.org/tmweb/help/help.en.html'"
                                       " | grep -i -A2 -B2 '" (shell-escape query) "' | head -20 > " ai-web-search-file " 2>/dev/null\n")))
    (string-save search-script (unix->url ai-script-file))
    (eval-system (string-append "/bin/bash " ai-script-file))
    (let ((result (string-load (unix->url ai-web-search-file))))
      (if (and result (> (string-length result) 0)) result ""))))

(define (ai-build-mogan-help-prompt question)
  (let ((web-info (ai-search-web question)))
    (string-append
     "You are an expert on Mogan STEM and GNU TeXmacs. Help with:\n"
     "- Math mode: press $ to enter math, Tab for autocomplete\n"
     "- Greek letters: type name + Tab (alpha -> alpha)\n"
     "- Fractions: Alt+F or /\n"
     "- Export: File -> Export -> PDF/LaTeX\n\n"
     (if (> (string-length web-info) 0) (string-append "Docs:\n" web-info "\n\n") "")
     "Question: " question "\n\nAnswer:")))

(define (ai-help-mogan question)
  (if (not (ai-ensure-ollama))
      (set-message "Error: Could not start Ollama" "AI")
      (let* ((full-prompt (ai-build-mogan-help-prompt question))
             (content (ai-send-request-raw full-prompt)))
        (if content
            (ai-write-scratch (string-append "Mogan Help: " question) content)
            (set-message "Error: No response from Ollama" "AI")))))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Interactive functions
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Claude
(tm-define (ai-ask-claude-interactive)
  (:synopsis "Ask Claude AI")
  (interactive (lambda (q) (when (and q (> (string-length q) 0)) (ai-ask-claude q)))
    (list "Ask Claude" "string" '())))

(tm-define (ai-ask-claude-with-context-interactive)
  (:synopsis "Ask Claude AI with document context")
  (interactive (lambda (q) (when (and q (> (string-length q) 0)) (ai-ask-claude-with-context q)))
    (list "Ask Claude (with context)" "string" '())))

;; Ollama
(tm-define (ai-ask-interactive)
  (:synopsis "Ask Ollama AI")
  (interactive (lambda (q) (when (and q (> (string-length q) 0)) (ai-ask q)))
    (list "Ask Ollama" "string" '())))

(tm-define (ai-ask-with-context-interactive)
  (:synopsis "Ask Ollama AI with document context")
  (interactive (lambda (q) (when (and q (> (string-length q) 0)) (ai-ask-with-context q)))
    (list "Ask Ollama (with context)" "string" '())))

(tm-define (ai-help-mogan-interactive)
  (:synopsis "Get help with Mogan STEM")
  (interactive (lambda (q)
    (when (and q (> (string-length q) 0))
      (let ((prompt (string-append "You are a Mogan STEM expert. Help with: " q)))
        (ai-ask-claude prompt))))
    (list "Help with Mogan" "string" '())))

(tm-define (ai-clear-history-interactive)
  (:synopsis "Clear conversation history")
  (ai-clear-history)
  (set-message "Conversation history cleared" "AI"))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PDF Support
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(tm-define (ai-load-pdf-interactive)
  (:synopsis "Load a PDF file for Claude to analyze")
  (set-message "Opening file picker..." "AI")
  ;; Write AppleScript to a file to avoid quoting issues
  (string-save
   (string-append "set theFile to choose file with prompt \"Select PDF file\" of type {\"pdf\", \"PDF\"} default location (path to documents folder)\n"
                  "return POSIX path of theFile\n")
   (unix->url "/tmp/mogan-ai-pick.scpt"))
  ;; Write bash script that runs osascript and saves result
  (string-save
   (string-append "#!/bin/bash\n"
                  "rm -f /tmp/mogan-ai-pick-result.txt\n"
                  "RESULT=$(osascript /tmp/mogan-ai-pick.scpt 2>/dev/null)\n"
                  "echo \"$RESULT\" > /tmp/mogan-ai-pick-result.txt\n"
                  "sync\n")
   (unix->url "/tmp/mogan-ai-pick.sh"))
  (system "/bin/bash /tmp/mogan-ai-pick.sh")
  (system "sleep 0.1")
  (let ((result (var-eval-system "cat /tmp/mogan-ai-pick-result.txt")))
    (if (and result (> (string-length result) 0))
        (begin
          (set! ai-loaded-pdf-path result)
          (set-message (string-append "PDF loaded: " result) "AI")
          (let ((safe-path (string-replace (string-replace result "_" "\\_") "&" "\\&")))
            (ai-write-scratch "Load PDF"
              (string-append "PDF loaded successfully.\n\n"
                             "File: " safe-path "\n\n"
                             "You can now use Ask about PDF to ask questions about this document."))))
        (set-message "No file selected" "AI"))))

(define (ai-ask-claude-about-pdf question)
  (if (or (not ai-loaded-pdf-path) (string=? ai-loaded-pdf-path ""))
      (set-message "Error: No PDF loaded. Use 'Load PDF' first." "AI")
      (if (or (not ai-claude-api-key) (string=? ai-claude-api-key ""))
          (set-message "Error: Claude API key not set" "AI")
          (begin
            (set-message "Asking Claude about PDF (please wait)..." "AI")
            (let* ((helper-src (string-append (getenv "HOME")
                                 "/Library/Application Support/moganlab/plugins/ai/bin/ai-helper.py"))
                   (helper-src-linux (string-append (getenv "HOME")
                                       "/.TeXmacs/plugins/ai/bin/ai-helper.py"))
                   (config-file "/tmp/mogan-ai-pdf-config.json")
                   (script-file "/tmp/mogan-ai-pdf-query.sh")
                   (output-file "/tmp/mogan-ai-pdf-output.txt"))
              (string-save
               (string-append "{\"provider\":\"claude\""
                              ",\"question\":\"" (json-escape-string question) "\""
                              ",\"pdf_path\":\"" (json-escape-string ai-loaded-pdf-path) "\""
                              ",\"api_key\":\"" ai-claude-api-key "\""
                              "}")
               (unix->url config-file))
              (string-save
               (string-append "#!/bin/bash\n"
                 "rm -f \"" output-file "\"\n"
                 "HELPER=\"" helper-src "\"\n"
                 "if [ ! -f \"$HELPER\" ]; then\n"
                 "  HELPER=\"" helper-src-linux "\"\n"
                 "fi\n"
                 "CONFIG=$(cat \"" config-file "\")\n"
                 "python3 \"$HELPER\" \"$CONFIG\" > \"" output-file "\" 2>&1\n"
                 "sync\n")
               (unix->url script-file))
              (system (string-append "/bin/bash " script-file))
              (system "sleep 0.1")
              (let ((result (var-eval-system (string-append "cat " output-file))))
                (if (and result (> (string-length result) 0))
                    (let ((json (parse-json-simple result)))
                      (if (assoc "answer" json)
                          (let ((answer (cdr (assoc "answer" json))))
                            (ai-add-to-history (string-append "[PDF] " question) answer)
                            (ai-write-scratch question (ai-strip-markdown answer)))
                          (let ((err (assoc "error" json)))
                            (set-message (string-append "Error: " (if err (cdr err) "Unknown")) "AI"))))
                    (set-message "Error: No response from Claude about PDF" "AI"))))))))

(tm-define (ai-ask-pdf-interactive)
  (:synopsis "Ask Claude about the loaded PDF")
  (interactive (lambda (q)
    (when (and q (> (string-length q) 0))
      (ai-ask-claude-about-pdf q)))
    (list "Ask about PDF" "string" '())))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; PDF to LaTeX conversion
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(define (ai-convert-pdf-to-latex)
  (if (or (not ai-loaded-pdf-path) (string=? ai-loaded-pdf-path ""))
      (set-message "Error: No PDF loaded. Use 'Load PDF' first." "AI")
      (if (or (not ai-claude-api-key) (string=? ai-claude-api-key ""))
          (set-message "Error: Claude API key not set" "AI")
          (begin
            (set-message "Converting PDF to LaTeX (this may take several minutes)..." "AI")
            (let* ((helper-src (string-append (getenv "HOME")
                                 "/Library/Application Support/moganlab/plugins/ai/bin/ai-helper.py"))
                   (helper-src-linux (string-append (getenv "HOME")
                                       "/.TeXmacs/plugins/ai/bin/ai-helper.py"))
                   (config-file "/tmp/mogan-ai-pdf-config.json")
                   (script-file "/tmp/mogan-ai-pdf-convert.sh")
                   (json-output "/tmp/mogan-ai-pdf-convert-output.txt")
                   (tex-file "/tmp/PDF-to-LaTeX.tex")
                   (status-file "/tmp/mogan-ai-convert-status.txt")
                   (question "Convert this entire PDF document to LaTeX source code. Reproduce ALL content as faithfully as possible including: text, section structure, equations, tables, theorem environments, references, and formatting. For charts and figures, describe them in comments. Output ONLY the LaTeX code starting from \\documentclass, with no explanation before or after. Use appropriate packages (amsmath, amssymb, amsthm, etc). Include \\usepackage[utf8]{inputenc} for proper encoding."))
              (string-save
               (string-append "{\"provider\":\"claude\""
                              ",\"question\":\"" (json-escape-string question) "\""
                              ",\"pdf_path\":\"" (json-escape-string ai-loaded-pdf-path) "\""
                              ",\"api_key\":\"" ai-claude-api-key "\""
                              "}")
               (unix->url config-file))
              (string-save
               (string-append "#!/bin/bash\n"
                 "rm -f " json-output " " tex-file " " status-file "\n"
                 "HELPER=\"" helper-src "\"\n"
                 "if [ ! -f \"$HELPER\" ]; then\n"
                 "  HELPER=\"" helper-src-linux "\"\n"
                 "fi\n"
                 "CONFIG=$(cat " config-file ")\n"
                 "python3 \"$HELPER\" \"$CONFIG\" > " json-output " 2>&1\n"
                 "python3 -c '\n"
                 "import json, re\n"
                 "with open(\"" json-output "\", encoding=\"utf-8\") as f:\n"
                 "    data = json.load(f)\n"
                 "if data.get(\"success\") and \"answer\" in data:\n"
                 "    text = data[\"answer\"]\n"
                 "    text = text.replace(\"**\", \"\")\n"
                 "    text = re.sub(r\"(?<=[A-Za-z])\\*(?=[A-Za-z])\", \"\", text)\n"
                 "    with open(\"" tex-file "\", \"w\", encoding=\"utf-8\") as f:\n"
                 "        f.write(text)\n"
                 "    if data.get(\"truncated\"):\n"
                 "        print(\"TRUNCATED\")\n"
                 "    else:\n"
                 "        print(\"OK\")\n"
                 "else:\n"
                 "    print(data.get(\"error\", \"Unknown error\"))\n"
                 "' > " status-file " 2>&1\n"
                 "sync\n")
               (unix->url script-file))
              (system (string-append "/bin/bash " script-file))
              (system "sleep 0.1")
              (let ((status (var-eval-system (string-append "cat " status-file))))
                (if (and status (string=? status "OK"))
                    (begin
                      (set-message (string-append "LaTeX saved to " tex-file) "AI")
                      (load-buffer (unix->url tex-file)))
                    (if (and status (string=? status "TRUNCATED"))
                        (begin
                          (set-message "Warning: Output truncated due to document size. LaTeX file is incomplete." "AI")
                          (load-buffer (unix->url tex-file)))
                        (set-message (string-append "Conversion error: " (or status "Unknown")) "AI")))))))))

(tm-define (ai-convert-pdf-interactive)
  (:synopsis "Convert loaded PDF to LaTeX")
  (ai-convert-pdf-to-latex))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Menu
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

(menu-bind ai-assistant-menu
  ("Ask Claude..." (ai-ask-claude-interactive))
  ("Ask Claude with Context..." (ai-ask-claude-with-context-interactive))
  ---
  ("Ask Ollama..." (ai-ask-interactive))
  ("Ask Ollama with Context..." (ai-ask-with-context-interactive))
  ---
  ("Load PDF..." (ai-load-pdf-interactive))
  ("Ask about PDF..." (ai-ask-pdf-interactive))
  ("Convert PDF to LaTeX" (ai-convert-pdf-interactive))
  ---
  ("Help with Mogan..." (ai-help-mogan-interactive))
  ---
  ("Toggle Context"
   (begin
     (set! ai-always-use-context (not ai-always-use-context))
     (set-message (if ai-always-use-context "Context: ON" "Context: OFF") "AI")))
  ---
  ("Clear History" (ai-clear-history-interactive)))

(menu-bind texmacs-extra-menu
  (former)
  (=> "AI" (link ai-assistant-menu)))
