;; Minimal home environment with norns, for testing:
;;   guix home build -L . examples/home-test.scm
(use-modules (gnu home) (gnu services) (norns-guix home services norns))

(home-environment
 (services
  (list (service home-norns-service-type))))
