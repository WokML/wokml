(module Main)
(import Base)
(import Control)
(sig (names producer) (with (-> (unit) U64) (row (slot (app Coro U64 U64)))))
(def producer (params (unit)) (infix (app (dot Coro suspend) 42) (+ 1)))
(sig (names main) U64)
(def
  main
  (params)
  (case
    (app start producer)
    (alt (pcon Completed r) r)
    (alt
      (pcon Suspended x g)
      (block
        (let (bind resumeLater (lam (params u) (app run g (infix x (* 10))))))
        (let (bind fs (list resumeLater)))
        99))))
