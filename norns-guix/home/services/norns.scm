(define-module (norns-guix home services norns)
  #:use-module (gnu home services)
  #:use-module (gnu home services shepherd)
  #:use-module (gnu packages audio)         ; supercollider
  #:use-module (gnu packages linux)         ; pipewire
  #:use-module (gnu services)
  #:use-module (gnu services configuration)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix records)
  #:use-module (srfi srfi-1)
  #:use-module (norns-guix packages norns)
  #:use-module (norns-guix packages norns-extras)
  #:export (home-norns-configuration
            home-norns-configuration?
            home-norns-service-type))

;;; Commentary:
;;;
;;; Run norns (crone, SuperCollider and matron) as Shepherd services of the
;;; user, with audio through PipeWire's JACK and the norns screen as a window
;;; on the desktop.
;;;
;;; norns finds everything through $HOME: its Lua, fonts and SuperCollider
;;; classes in ~/norns, scripts in ~/dust, ~/matronrc.lua, and sclang's
;;; config.  So the services run with HOME (and the XDG directories) set to
;;; a directory of their own, by default ~/.local/share/norns, which keeps
;;; norns out of your real home and away from your own SuperCollider setup.
;;;
;;;   herd start norns     start everything
;;;   herd stop norns      stop everything
;;;
;;; Code:

(define-record-type* <home-norns-configuration>
  home-norns-configuration make-home-norns-configuration
  home-norns-configuration?
  (norns          home-norns-configuration-norns
                  (default norns))
  (supercollider  home-norns-configuration-supercollider
                  (default supercollider))
  ;; Extra SuperCollider extensions, each a package installing classes
  ;; under share/SuperCollider/Extensions and/or UGens under
  ;; lib/SuperCollider/plugins.
  (sc-extensions  home-norns-configuration-sc-extensions
                  (default (list sc3-plugins)))
  ;; The pipewire package whose pw-jack runs the audio processes; #f to use
  ;; whatever JACK server libjack finds.
  (pipewire       home-norns-configuration-pipewire
                  (default pipewire))
  ;; norns' home; #f means ~/.local/share/norns.
  (directory      home-norns-configuration-directory
                  (default #f))
  ;; An existing dust directory (scripts, data, audio) to use instead of a
  ;; fresh one, e.g. "~/git/norns-desktop/dust".
  (dust-directory home-norns-configuration-dust-directory
                  (default #f))
  ;; sclang's startup file.  The default gives SuperCollider four outputs:
  ;; norns uses the first two, and scripts like 4deck send a headphone cue
  ;; to the other two.
  (supercollider-startup
   home-norns-configuration-supercollider-startup
   (default "Server.local.options.numOutputBusChannels = 4;\n"))
  ;; maiden, the web editor (on maiden-port); #f for none.
  (maiden         home-norns-configuration-maiden
                  (default maiden))
  (maiden-port    home-norns-configuration-maiden-port
                  (default 5000))
  ;; Address maiden and the matron and sclang REPLs (ports 5555 and 5556,
  ;; which maiden's page connects to) listen on.  Anyone who can reach them
  ;; can run code as you, so the default is this machine only; "*" listens
  ;; on every interface, as a norns does.
  (repl-address   home-norns-configuration-repl-address
                  (default "127.0.0.1"))
  ;; How the screen window looks: 'red-lcd (a 1970s red backlit display)
  ;; or 'plain (the bare pixels, scaled).
  (screen-style   home-norns-configuration-screen-style
                  (default 'red-lcd))
  ;; Directory for the services' logs; #f means ~/.local/var/log.
  (log-directory  home-norns-configuration-log-directory
                  (default #f))
  (auto-start?    home-norns-configuration-auto-start?
                  (default #f)))

;;; Stand-ins for the commands norns runs through sudo/systemctl.
(define norns-shims
  (computed-file
   "norns-shims"
   (with-imported-modules '((guix build utils))
     #~(begin
         (use-modules (guix build utils))
         (define (script name text)
           (let ((file (string-append #$output "/bin/" name)))
             (call-with-output-file file
               (lambda (port) (display text port)))
             (chmod file #o755)))
         (mkdir-p (string-append #$output "/bin"))
         (script "sudo" "#!/bin/sh
# norns runs a few commands through sudo; run them as the user.
while [ $# -gt 0 ]; do
    case \"$1\" in
        -u|-g|-p|-C) shift 2 ;;
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
exec \"$@\"
")
         (script "systemctl" "#!/bin/sh
# SYSTEM > RESTART runs \"systemctl restart\" on norns-sclang, norns-crone and
# norns-matron, one at a time from inside matron, so restarting matron kills
# the rest of the sequence.  The first call restarts all of norns, detached.
case \"$1\" in
    restart|try-restart|reload-or-restart) ;;
    *) echo \"systemctl (norns): ignoring $*\" >&2; exit 0 ;;
esac
lock=\"${XDG_RUNTIME_DIR:-/tmp}/norns-restart\"
find \"$lock\" -maxdepth 0 -mmin +1 -exec rmdir {} \\; 2>/dev/null
mkdir \"$lock\" 2>/dev/null || exit 0
setsid -f sh -c 'herd restart norns; rmdir \"$0\"' \"$lock\" >/dev/null 2>&1
")))))

;;; Gexp evaluating, inside shepherd, to norns' home directory.
(define (norns-home-gexp config)
  (let ((dir (home-norns-configuration-directory config)))
    #~(let ((home (getenv "HOME")))
        (define (expand path)
          (if (string-prefix? "~/" path)
              (string-append home (string-drop path 1))
              path))
        #$(if dir
              #~(expand #$dir)
              #~(string-append home "/.local/share/norns")))))

(define (log-file-gexp config name)
  (let ((dir (home-norns-configuration-log-directory config)))
    #~(string-append
       #$(or dir #~(string-append (getenv "HOME") "/.local/var/log"))
       "/" #$name ".log")))

;;; Sets up norns' home: the norns tree, dust, matronrc.lua and
;;; SuperCollider's config and extensions.  Run before every start, so it
;;; tracks package upgrades.
(define (norns-setup-program config)
  (match-record config <home-norns-configuration>
    (norns sc-extensions dust-directory supercollider-startup maiden)
    (program-file
     "norns-setup"
     (with-imported-modules '((guix build utils))
       #~(begin
           (use-modules (guix build utils) (ice-9 ftw) (ice-9 match))
           (define home (getenv "HOME"))
           (define nhome (cadr (command-line)))
           (define (expand path)
             (if (string-prefix? "~/" path)
                 (string-append home (string-drop path 1))
                 path))
           (define (symlink? path)
             (false-if-exception
              (eq? 'symlink (stat:type (lstat path)))))
           ;; Point LINK at TARGET, replacing an old symlink (never a real
           ;; file or directory).
           (define (link! target link)
             (when (symlink? link)
               (delete-file link))
             (if (file-exists? link)
                 (format (current-error-port)
                         "norns-setup: ~a exists and isn't a symlink; \
leaving it~%" link)
                 (symlink target link)))
           (define (write-file! file text)
             (mkdir-p (dirname file))
             (call-with-output-file file
               (lambda (port) (display text port))))

           (define sc-config (string-append nhome "/.config/SuperCollider"))
           (define sc-ext
             (string-append nhome "/.local/share/SuperCollider/Extensions"))

           (for-each mkdir-p
                     (list nhome sc-config sc-ext
                           (string-append nhome "/.cache")
                           (string-append nhome "/.local/state")))
           (link! #$(file-append norns "/share/norns")
                  (string-append nhome "/norns"))

           ;; dust: scripts, their data and audio.
           (let ((dust (string-append nhome "/dust")))
             #$(if dust-directory
                   #~(link! (expand #$dust-directory) dust)
                   #~(for-each (lambda (d) (mkdir-p (string-append dust d)))
                               '("/code" "/data" "/audio/tape"))))

           ;; maiden: the script catalog's sources (what its
           ;; project-setup.sh does), keeping any already there.
           #$@(if maiden
                  (list
                   #~(let ((data (string-append nhome "/dust/data")))
                       (mkdir-p (string-append data "/catalogs"))
                       (for-each
                        (lambda (src)
                          (let ((dst (string-append data "/sources/"
                                                    (basename src))))
                            (unless (file-exists? dst)
                              (mkdir-p (dirname dst))
                              (copy-file src dst)
                              (chmod dst #o644))))
                        (find-files #$(file-append maiden
                                                   "/share/maiden/dist/sources")
                                    "\\.json$"))))
                  '())

           ;; matron: the screen as an SDL window.
           (write-file! (string-append nhome "/matronrc.lua")
                        "_boot.add_io('screen:sdl', {})\n")

           ;; SuperCollider: the norns classes and engines (in dust), with
           ;; norns-config.sc and the extensions alongside.
           (write-file! (string-append sc-config "/sclang_conf.yaml")
                        (string-append
                         "includePaths:\n"
                         "    -   " nhome "/norns/sc/core\n"
                         "    -   " nhome "/norns/sc/engines\n"
                         "    -   " nhome "/dust\n"
                         "excludePaths:\n    []\n"
                         "postInlineWarnings: false\n"
                         "excludeDefaultPaths: false\n"))
           (write-file! (string-append sc-config "/startup.scd")
                        #$supercollider-startup)
           ;; Drop links from earlier generations, then link the current
           ;; extensions.
           (for-each (lambda (f)
                       (let ((path (string-append sc-ext "/" f)))
                         (when (symlink? path) (delete-file path))))
                     (scandir sc-ext
                              (lambda (f) (not (member f '("." ".."))))))
           (link! #$(file-append norns "/share/norns/sc/norns-config.sc")
                  (string-append sc-ext "/norns-config.sc"))
           (for-each
            (match-lambda
              ((name . dir)
               (for-each
                (lambda (sub)
                  (let ((src (string-append dir sub)))
                    (when (file-exists? src)
                      (link! src (string-append sc-ext "/" name "-"
                                                (basename sub))))))
                '("/share/SuperCollider/Extensions"
                  "/lib/SuperCollider/plugins"))))
            '#$(map (lambda (p)
                      #~(#$(package-name p) . #$p))
                    sc-extensions)))))))

(define (norns-shepherd-services config)
  (match-record config <home-norns-configuration>
    (norns supercollider pipewire repl-address maiden maiden-port
     screen-style auto-start?)
    (define nhome (norns-home-gexp config))
    (define (repl-url port)
      (string-append "ws://" repl-address ":" (number->string port)))
    (define pw-jack
      (if pipewire
          #~(list #$(file-append pipewire "/bin/pw-jack"))
          #~'()))
    ;; The environment of every norns process.
    (define (environment . extra)
      #~(let* ((nhome #$nhome)
               (overrides
                (list (string-append "HOME=" nhome)
                      (string-append "XDG_CONFIG_HOME=" nhome "/.config")
                      (string-append "XDG_DATA_HOME=" nhome "/.local/share")
                      (string-append "XDG_CACHE_HOME=" nhome "/.cache")
                      (string-append "XDG_STATE_HOME=" nhome "/.local/state")
                      (string-append "PATH=" #$norns-shims "/bin:"
                                     (or (getenv "PATH") "/run/current-system/profile/bin"))
                      "JACK_NO_START_SERVER=1"
                      "JACK_NO_AUDIO_RESERVATION=1"))
               (extra (list #$@extra))
               (names (map (lambda (kv)
                             (string-take kv (string-index kv #\=)))
                           (append overrides extra))))
          (append overrides extra
                  (remove (lambda (kv)
                            (let ((i (string-index kv #\=)))
                              (and i (member (string-take kv i) names))))
                          (environ)))))
    (define (daemon name doc requirement command . extra-env)
      (shepherd-service
       (provision (list name))
       (requirement requirement)
       (documentation doc)
       (auto-start? #f)
       (modules '((srfi srfi-1) (ice-9 ftw)))
       (start #~(make-forkexec-constructor
                 (append #$pw-jack #$command)
                 #:directory #$nhome
                 #:environment-variables #$(apply environment extra-env)
                 #:log-file #$(log-file-gexp config (symbol->string name))))
       (stop stop-process-group)
       (respawn? #t)))
    ;; Like systemd stopping a unit: SIGTERM the whole process group, wait
    ;; for all of it (not just the main process, which for matron and
    ;; sclang is ws-wrapper), then SIGKILL what's left.  That also takes
    ;; down helpers a script started, which would otherwise keep matron's
    ;; OSC port.
    (define stop-process-group
      #~(lambda (process . _)
          ;; Shepherd starts each service in a session of its own (and
          ;; pw-jack execs in place), so the service's PID is its PGID.
          (let ((pgid (if (integer? process) process (process-id process))))
            ((make-kill-destructor) process)
            (let loop ((tries 50))
              (when (false-if-exception (begin (kill (- pgid) 0) #t))
                (if (zero? tries)
                    (false-if-exception (kill (- pgid) SIGKILL))
                    (begin
                      ((@ (fibers) sleep) 0.1)
                      (loop (- tries 1))))))
            #f)))
    ;; Stop matron, crone and sclang (and so whatever depends on them).
    (define stop-daemons
      #~(lambda ()
          (for-each (lambda (name)
                      (let ((service (lookup-service name)))
                        (when (and service (service-running? service))
                          (stop-service service))))
                    '(norns-maiden norns-matron norns-crone norns-sclang))))
    (define ws-wrapper (file-append norns "/bin/ws-wrapper"))
    ;; maiden, started by shepherd on the first connection to its port, as
    ;; on a norns (socket activation; maiden serves on fd 3).
    (define maiden-service
      (and maiden
           (let ((share (file-append maiden "/share/maiden"))
                 (address (if (string=? repl-address "*")
                              "0.0.0.0"
                              repl-address)))
             (shepherd-service
              (provision '(norns-maiden))
              (requirement '(norns-setup))
              (documentation
               (string-append "maiden, norns' web editor (http://localhost:"
                              (number->string maiden-port) ")."))
              (auto-start? #f)
              (modules '((shepherd endpoints) (srfi srfi-1) (ice-9 ftw)))
              (start #~(make-systemd-constructor
                        (list #$(file-append maiden "/bin/maiden")
                              "server" "--fd" "3"
                              "--config" #$(file-append share "/maiden.yaml")
                              "--app" #$(file-append share "/app/build")
                              "--data" (string-append #$nhome "/dust")
                              "--doc" (string-append #$nhome "/norns/doc"))
                        (list (endpoint
                               (make-socket-address
                                AF_INET (inet-pton AF_INET #$address)
                                #$maiden-port)
                               #:name "http"))
                        #:directory #$nhome
                        #:environment-variables #$(environment)
                        #:log-file #$(log-file-gexp config "norns-maiden")))
              (stop #~(make-systemd-destructor))))))
    ;; matron opens its window on the session's Wayland display; shepherd
    ;; usually starts before the compositor, so find its socket.
    (define wayland-display
      #~(string-append
         "WAYLAND_DISPLAY="
         (or (getenv "WAYLAND_DISPLAY")
             (let* ((runtime (or (getenv "XDG_RUNTIME_DIR") "/tmp"))
                    (sockets (or (scandir runtime
                                          (lambda (f)
                                            (and (string-prefix? "wayland-" f)
                                                 (not (string-suffix? ".lock" f)))))
                                 '())))
               (if (null? sockets) "wayland-0" (car sockets))))))

    (filter
     identity
     (list
     (shepherd-service
      (provision '(norns-setup))
      (documentation "Prepare norns' home directory.")
      (one-shot? #t)
      (auto-start? #f)
      (start #~(lambda _
                 (zero? (system* #$(norns-setup-program config) #$nhome)))))
     (daemon 'norns-crone "norns crone: mixer, softcut and tape."
             '(norns-setup)
             #~(list #$(file-append norns "/bin/crone")))
     (daemon 'norns-sclang "SuperCollider for norns (REPL on port 5556)."
             '(norns-setup)
             #~(list #$ws-wrapper #$(repl-url 5556)
                     #$(file-append supercollider "/bin/sclang") "-i" "maiden")
             ;; sclang is built with Qt but runs headless here.
             "QT_QPA_PLATFORM=offscreen")
     (daemon 'norns-matron "norns matron: scripts and screen (REPL on port 5555)."
             '(norns-setup norns-crone norns-sclang)
             #~(list #$ws-wrapper #$(repl-url 5555)
                     #$(file-append norns "/bin/matron"))
             wayland-display
             (string-append "NORNS_SCREEN_STYLE=" (symbol->string screen-style)))
     maiden-service
     (shepherd-service
      (provision '(norns))
      (requirement (if maiden '(norns-matron norns-maiden) '(norns-matron)))
      (documentation "norns: crone, SuperCollider and matron.")
      (auto-start? auto-start?)
      (start #~(const #t))
      ;; Starting norns starts its requirements, but stopping it only stops
      ;; services that depend on it, so stop the daemons too: `herd stop
      ;; norns' means all of them.  That can't happen inside this procedure
      ;; (stopping them queries this service, which is busy until it
      ;; returns), so a fiber does it once norns has stopped -- unless norns
      ;; is being restarted (see the restart action).
      (stop #~(lambda _
                ((@ (fibers) spawn-fiber)
                 (lambda ()
                   (let ((self (lookup-service 'norns)))
                     (let wait ()
                       ((@ (fibers) sleep) 0.25)
                       (unless (or (service-stopped? self)
                                   (service-running? self))
                         (wait)))
                     (when (and (service-stopped? self)
                                (not (object-property self 'norns-restarting)))
                       (#$stop-daemons)))))
                #f))
      ;; `herd restart norns' restarts all of norns: stop the daemons (which
      ;; stops norns, their dependent), then start norns (which starts them).
      ;; Also what SYSTEM > RESTART does.
      (actions
       (list (shepherd-action
              (name 'restart)
              (documentation "Restart crone, SuperCollider and matron.")
              (procedure
               #~(lambda _
                   (let ((self (lookup-service 'norns)))
                     (set-object-property! self 'norns-restarting #t)
                     (#$stop-daemons)
                     (start-service self)
                     (set-object-property! self 'norns-restarting #f)
                     #t)))))))))))

(define home-norns-service-type
  (service-type
   (name 'home-norns)
   (extensions
    (list (service-extension home-shepherd-service-type
                             norns-shepherd-services)))
   (default-value (home-norns-configuration))
   (description
    "Run norns as user Shepherd services: crone and SuperCollider through
PipeWire's JACK, and matron with its screen in a window.  Start it with
@command{herd start norns}.")))
