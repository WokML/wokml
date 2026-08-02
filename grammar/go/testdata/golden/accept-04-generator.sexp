(module Main)
(import Base)
(effect Yield (params a) (op yield (-> a (unit))))
(sig (names collect) (app Handler (app Yield a) r (list a)))
(def
  collect
  (params)
  (handler
    Yield
    (once yield (args x) (k k) (infix x (:: (app k (unit)))))
    (return u (list))))
(sig
  (names count)
  (with (-> U64 (-> U64 (unit))) (row (slot (app Yield U64)))))
(def
  count
  (params lo hi)
  (case
    (infix lo (== hi))
    (alt (pcon True) (unit))
    (alt
      (pcon False)
      (block (app (dot Yield yield) lo) (app count (infix lo (+ 1)) hi)))))
(sig (names main) (list U64))
(def main (params) (handle-in (elided) collect (app count 1 7)))
