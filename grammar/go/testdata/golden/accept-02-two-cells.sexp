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
(sig
  (names transfer)
  (with
    (-> (unit) (unit))
    (row (role from (app State U64)) (role to (app State U64)))))
(def
  transfer
  (params (unit))
  (block
    (let (bind amt (dot from get)))
    (app (dot from set) 0)
    (app (dot to set) (infix (dot to get) (+ amt)))))
(sig (names main) (tuple (tuple (unit) U64) U64))
(def
  main
  (params)
  (block
    (handle (role from) (app state 100))
    (handle (role to) (app state 5))
    (app transfer (unit))))
