(module Main)
(import Base)
(effect State (params s) (op get s) (op set (-> s (unit))))
(sig (names state) (-> s (app Handler (app State s) a (tuple a s))))
(def
  state
  (params init)
  (handler
    State
    (var cur init)
    (clause get (args) cur)
    (clause set (args x) (:= cur x))
    (return v (tuple v cur))))
(sig (names needsAmbient) (with (-> (unit) U64) (row (slot (app State U64)))))
(def needsAmbient (params (unit)) (dot State get))
(sig (names main) (tuple (tuple U64 U64) U64))
(def
  main
  (params)
  (block
    (handle (role a) (app state 1))
    (handle (role b) (app state 2))
    (app needsAmbient (unit))))
