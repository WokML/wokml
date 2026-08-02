(module Main)
(import Base)
(effect Call (params) (op call (-> (-> U64 U64) U64)))
(sig (names useCall) (with (-> (unit) U64) (row (slot Call))))
(def
  useCall
  (params (unit))
  (app (dot Call call) (lam (params n) (infix n (+ 1)))))
(sig (names bad) (app Handler Call a a))
(def bad (params) (handler Call (once call (args) (k k) (app k 41))))
(sig (names main) U64)
(def main (params) (handle-in (elided) bad (app useCall (unit))))
