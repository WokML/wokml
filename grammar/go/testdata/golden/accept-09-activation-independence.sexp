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
(sig (names main) (tuple U64 U64))
(def
  main
  (params)
  (block
    (let (bind h (app state 0)))
    (let (bind (tuple x s1) (handle-in (elided) h (app (dot State set) 1))))
    (let (bind (tuple y s2) (handle-in (elided) h (dot State get))))
    (tuple s1 s2)))
