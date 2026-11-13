;;; Example Guix System configuration for running monome norns natively.
;;;
;;; This is a minimal system config that boots into a console with the
;;; norns services running.  Access the maiden web IDE at:
;;;   http://localhost:5000
;;;
;;; To build a VM image for testing:
;;;   guix system vm -L /path/to/norns-guix system-example.scm
;;;
;;; To build a full disk image:
;;;   guix system image -L /path/to/norns-guix system-example.scm

(use-modules (gnu)
             (gnu services)
             (norns-guix services norns))

(use-service-modules networking ssh)

(operating-system
  (host-name "norns-desktop")
  (timezone "America/New_York")
  (locale "en_US.utf8")

  (bootloader (bootloader-configuration
               (bootloader grub-bootloader)
               (targets '("/dev/sda"))))

  (file-systems (cons (file-system
                        (device "/dev/sda1")
                        (mount-point "/")
                        (type "ext4"))
                      %base-file-systems))

  (users (cons (user-account
                (name "user")
                (group "users")
                (supplementary-groups '("wheel" "audio" "video" "input"))
                (home-directory "/home/user"))
               %base-user-accounts))

  (packages (append
             (list)
             %base-packages))

  (services (append
             (list
              ;; norns sound computer services.
              (service norns-service-type
                       (norns-configuration
                        ;; Adjust to match your audio interface:
                        (jack-device "hw:0")
                        (sample-rate 48000)
                        (period-size 128)
                        (periods 3)
                        ;; Data directory for dust scripts/audio:
                        (data-dir "/home/norns")))

              ;; Basic networking.
              (service dhcp-client-service-type)

              ;; SSH for remote access.
              (service openssh-service-type
                       (openssh-configuration
                        (permit-root-login #f))))
             %base-services)))
