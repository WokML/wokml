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
(sig (names main) U64)
(def
  main
  (params)
  (block (let (bind x (handle-in (role c) (app state 0) c))) 0))
