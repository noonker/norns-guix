(define-module (norns-guix services norns)
  #:use-module (gnu services)
  #:use-module (gnu services shepherd)
  #:use-module (gnu services configuration)
  #:use-module (gnu system pam)
  #:use-module (gnu system shadow)
  #:use-module (guix gexp)
  #:use-module (guix records)
  #:use-module (guix packages)
  #:use-module (gnu packages audio)
  #:use-module (gnu packages xorg)
  #:use-module (norns-guix packages norns)
  #:use-module (norns-guix packages norns-extras)
  #:export (norns-configuration
            norns-configuration?
            norns-configuration-norns
            norns-configuration-maiden
            norns-configuration-supercollider
            norns-configuration-sc3-plugins
            norns-configuration-user
            norns-configuration-group
            norns-configuration-jack-device
            norns-configuration-sample-rate
            norns-configuration-period-size
            norns-configuration-periods
            norns-configuration-display
            norns-configuration-data-dir
            norns-configuration-maiden-port
            norns-service-type))

;;;
;;; Configuration record
;;;

(define-record-type* <norns-configuration>
  norns-configuration make-norns-configuration
  norns-configuration?
  ;; Package references.
  (norns          norns-configuration-norns
                  (default norns))
  (maiden         norns-configuration-maiden
                  (default maiden))
  (supercollider  norns-configuration-supercollider
                  (default supercollider))
  (sc3-plugins    norns-configuration-sc3-plugins
                  (default sc3-plugins))
  ;; User/group for the service processes.
  (user           norns-configuration-user
                  (default "norns"))
  (group          norns-configuration-group
                  (default "norns"))
  ;; JACK audio settings.
  (jack-device    norns-configuration-jack-device
                  (default "hw:0"))
  (sample-rate    norns-configuration-sample-rate
                  (default 48000))
  (period-size    norns-configuration-period-size
                  (default 128))
  (periods        norns-configuration-periods
                  (default 3))
  ;; Display for Xvfb (matron needs an X display for SDL2).
  (display        norns-configuration-display
                  (default ":0"))
  ;; Data directory (replaces /home/we in stock norns).
  (data-dir       norns-configuration-data-dir
                  (default "/home/norns"))
  ;; Maiden web IDE port.
  (maiden-port    norns-configuration-maiden-port
                  (default 5000)))


;;;
;;; Individual Shepherd services
;;;

;;; 1. Xvfb -- virtual X11 framebuffer for matron's SDL2 screen
(define (norns-xvfb-shepherd-service config)
  (let ((display (norns-configuration-display config))
        (user    (norns-configuration-user config)))
    (list
     (shepherd-service
      (provision '(norns-xvfb))
      (requirement '(user-processes))
      (documentation "Virtual X11 framebuffer for norns matron.")
      (start #~(make-forkexec-constructor
                (list #$(file-append xorg-server "/bin/Xvfb")
                      #$display
                      "-screen" "0" "128x64x16"
                      "-nolisten" "tcp")
                #:user #$user
                #:log-file "/var/log/norns-xvfb.log"))
      (stop #~(make-kill-destructor))))))

;;; 2. JACK -- audio server
(define (norns-jack-shepherd-service config)
  (let ((user        (norns-configuration-user config))
        (jack-device (norns-configuration-jack-device config))
        (sample-rate (norns-configuration-sample-rate config))
        (period-size (norns-configuration-period-size config))
        (periods     (norns-configuration-periods config)))
    (list
     (shepherd-service
      (provision '(norns-jack))
      (requirement '(norns-xvfb))
      (documentation "JACK audio server for norns.")
      (start #~(make-forkexec-constructor
                (list #$(file-append jack-2 "/bin/jackd")
                      "-R" "-P" "95"
                      "-d" "alsa"
                      "-d" #$jack-device
                      "-r" #$(number->string sample-rate)
                      "-n" #$(number->string periods)
                      "-p" #$(number->string period-size)
                      "-S" "-s")
                #:user #$user
                #:environment-variables
                (list "JACK_NO_START_SERVER=1"
                      "JACK_NO_AUDIO_RESERVATION=1")
                #:log-file "/var/log/norns-jack.log"))
      (stop #~(make-kill-destructor))))))

;;; 3. crone -- norns audio engine (SuperCollider wrapper)
(define (norns-crone-shepherd-service config)
  (let ((norns-pkg (norns-configuration-norns config))
        (user      (norns-configuration-user config))
        (data-dir  (norns-configuration-data-dir config)))
    (list
     (shepherd-service
      (provision '(norns-crone))
      (requirement '(norns-jack))
      (documentation "norns crone audio engine.")
      (start #~(make-forkexec-constructor
                (list #$(file-append norns-pkg "/bin/crone"))
                #:user #$user
                #:environment-variables
                (list "JACK_NO_START_SERVER=1"
                      "JACK_NO_AUDIO_RESERVATION=1"
                      (string-append "NORNS_HOME=" #$data-dir)
                      (string-append "NORNS_LUA="
                                     #$norns-pkg "/share/norns/lua")
                      (string-append "NORNS_SC="
                                     #$norns-pkg "/share/norns/sc"))
                #:log-file "/var/log/norns-crone.log"))
      (stop #~(make-kill-destructor))))))

;;; 4. sclang -- SuperCollider language interpreter (via ws-wrapper)
(define (norns-sclang-shepherd-service config)
  (let ((norns-pkg    (norns-configuration-norns config))
        (sc-pkg       (norns-configuration-supercollider config))
        (sc3-pkg      (norns-configuration-sc3-plugins config))
        (user         (norns-configuration-user config))
        (data-dir     (norns-configuration-data-dir config)))
    (list
     (shepherd-service
      (provision '(norns-sclang))
      (requirement '(norns-jack))
      (documentation "SuperCollider sclang for norns (via ws-wrapper).")
      (start #~(make-forkexec-constructor
                (list #$(file-append norns-pkg "/bin/ws-wrapper")
                      "ws://*:5556"
                      #$(file-append sc-pkg "/bin/sclang")
                      "-i" "maiden")
                #:user #$user
                #:environment-variables
                (list "JACK_NO_START_SERVER=1"
                      "JACK_NO_AUDIO_RESERVATION=1"
                      (string-append "NORNS_HOME=" #$data-dir)
                      (string-append "NORNS_LUA="
                                     #$norns-pkg "/share/norns/lua")
                      (string-append "NORNS_SC="
                                     #$norns-pkg "/share/norns/sc")
                      ;; Tell SC where to find sc3-plugins UGens.
                      (string-append "SC_PLUGIN_PATH="
                                     #$sc3-pkg
                                     "/lib/SuperCollider/plugins"))
                #:log-file "/var/log/norns-sclang.log"))
      (stop #~(make-kill-destructor))))))

;;; 5. matron -- norns script engine / UI (via ws-wrapper)
(define (norns-matron-shepherd-service config)
  (let ((norns-pkg (norns-configuration-norns config))
        (user      (norns-configuration-user config))
        (display   (norns-configuration-display config))
        (data-dir  (norns-configuration-data-dir config)))
    (list
     (shepherd-service
      (provision '(norns-matron))
      (requirement '(norns-crone norns-sclang))
      (documentation "norns matron script engine (via ws-wrapper).")
      (start #~(make-forkexec-constructor
                (list #$(file-append norns-pkg "/bin/ws-wrapper")
                      "ws://*:5555"
                      #$(file-append norns-pkg "/bin/matron"))
                #:user #$user
                #:environment-variables
                (list (string-append "DISPLAY=" #$display)
                      "JACK_NO_START_SERVER=1"
                      "JACK_NO_AUDIO_RESERVATION=1"
                      (string-append "NORNS_HOME=" #$data-dir)
                      (string-append "NORNS_LUA="
                                     #$norns-pkg "/share/norns/lua")
                      (string-append "NORNS_SC="
                                     #$norns-pkg "/share/norns/sc"))
                #:log-file "/var/log/norns-matron.log"))
      (stop #~(make-kill-destructor))))))

;;; 6. maiden -- web IDE
(define (norns-maiden-shepherd-service config)
  (let ((maiden-pkg  (norns-configuration-maiden config))
        (norns-pkg   (norns-configuration-norns config))
        (user        (norns-configuration-user config))
        (data-dir    (norns-configuration-data-dir config))
        (maiden-port (norns-configuration-maiden-port config)))
    (list
     (shepherd-service
      (provision '(norns-maiden))
      (requirement '(norns-matron))
      (documentation "maiden web IDE for norns.")
      (start #~(make-forkexec-constructor
                (list #$(file-append maiden-pkg "/bin/maiden")
                      "server"
                      "--port" #$(number->string maiden-port)
                      "--app"
                      #$(file-append maiden-pkg "/share/maiden/app/build")
                      "--data" #$(string-append data-dir "/dust")
                      "--doc"
                      #$(file-append norns-pkg "/share/norns/doc"))
                #:user #$user
                #:directory #$data-dir
                #:log-file "/var/log/norns-maiden.log"))
      (stop #~(make-kill-destructor))))))

;;; 7. watcher -- device hotplug monitor
(define (norns-watcher-shepherd-service config)
  (let ((norns-pkg (norns-configuration-norns config))
        (user      (norns-configuration-user config))
        (data-dir  (norns-configuration-data-dir config)))
    (list
     (shepherd-service
      (provision '(norns-watcher))
      (requirement '(user-processes))
      (documentation "norns watcher for device hotplug events.")
      (start #~(make-forkexec-constructor
                (list #$(file-append norns-pkg "/bin/watcher"))
                #:user #$user
                #:environment-variables
                (list (string-append "NORNS_HOME=" #$data-dir))
                #:log-file "/var/log/norns-watcher.log"))
      (stop #~(make-kill-destructor))))))


;;;
;;; System user account
;;;

(define (norns-accounts config)
  (let ((user  (norns-configuration-user config))
        (group (norns-configuration-group config)))
    (list
     (user-group
      (name group)
      (system? #t))
     (user-account
      (name user)
      (group group)
      (supplementary-groups '("audio" "input" "video"))
      (system? #t)
      (home-directory (norns-configuration-data-dir config))
      (comment "norns service account")))))


;;;
;;; Activation -- create data directories
;;;

(define (norns-activation config)
  (let ((user     (norns-configuration-user config))
        (group    (norns-configuration-group config))
        (data-dir (norns-configuration-data-dir config)))
    #~(begin
        (use-modules (guix build utils))
        (let ((mkdir-p/chown
               (lambda (dir)
                 (mkdir-p dir)
                 (let ((pw (getpw #$user)))
                   (chown dir (passwd:uid pw) (passwd:gid pw))))))
          ;; Create the norns data directories.
          (for-each mkdir-p/chown
                    (list #$data-dir
                          (string-append #$data-dir "/dust")
                          (string-append #$data-dir "/dust/code")
                          (string-append #$data-dir "/dust/data")
                          (string-append #$data-dir "/dust/audio")))))))


;;;
;;; PAM limits for realtime audio
;;;

(define (norns-pam-limits config)
  (list
   (pam-limits-entry
    (domain (string-append "@" (norns-configuration-group config)))
    (type 'both)
    (item 'rtprio)
    (value "95"))
   (pam-limits-entry
    (domain (string-append "@" (norns-configuration-group config)))
    (type 'both)
    (item 'memlock)
    (value "unlimited"))))


;;;
;;; Combined Shepherd services
;;;

(define (norns-shepherd-services config)
  "Return the list of all norns Shepherd services for CONFIG."
  (append (norns-xvfb-shepherd-service config)
          (norns-jack-shepherd-service config)
          (norns-crone-shepherd-service config)
          (norns-sclang-shepherd-service config)
          (norns-matron-shepherd-service config)
          (norns-maiden-shepherd-service config)
          (norns-watcher-shepherd-service config)))


;;;
;;; Composite service type
;;;

(define norns-service-type
  (service-type
   (name 'norns)
   (description "Run the monome norns sound computer platform as a set
of Shepherd services: Xvfb, JACK, crone, sclang, matron, maiden, and
watcher.")
   (extensions
    (list
     ;; All seven Shepherd services combined.
     (service-extension shepherd-root-service-type
                        norns-shepherd-services)
     ;; User account and group.
     (service-extension account-service-type
                        norns-accounts)
     ;; Data directory creation.
     (service-extension activation-service-type
                        norns-activation)
     ;; Realtime audio PAM limits.
     (service-extension pam-limits-service-type
                        norns-pam-limits)))
   (default-value (norns-configuration))))
