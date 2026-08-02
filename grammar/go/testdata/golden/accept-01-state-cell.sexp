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
  (names sumList)
  (with (-> (list U64) (unit)) (row (role st (app State U64)))))
(def
  sumList
  (params xs)
  (case
    xs
    (alt (list) (unit))
    (alt
      (:: y ys)
      (block (app (dot st set) (infix (dot st get) (+ y))) (app sumList ys)))))
(sig (names main) U64)
(def
  main
  (params)
  (block
    (let
      (bind
        (tuple u total)
        (handle-in
          (role st)
          (app state 0)
          (app sumList (list 3 1 4 1 5 9 2 6)))))
    total))
