(module Main)
(import Base)
(sig (names main) U64)
(def main (params) (block (let (bind s 5)) (:= s 6) s))
