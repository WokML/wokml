(module Main)
(import Base)
(effect Tick (params) (op tick (-> U64 U64)))
(sig (names bad) (app Handler Tick U64 U64))
(def
  bad
  (params)
  (handler
    Tick
    (once
      tick
      (args x)
      (k k)
      (block (let (bind a (app k (infix x (+ 1))))) (app k (infix a (+ 1)))))))
(sig (names useTick) (with (-> (unit) U64) (row (slot Tick))))
(def useTick (params (unit)) (app (dot Tick tick) 41))
(sig (names main) U64)
(def main (params) (handle-in (elided) bad (app useTick (unit))))
