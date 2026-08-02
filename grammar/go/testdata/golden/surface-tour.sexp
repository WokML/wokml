(module Main.Tour)
(import Base)
(import Geometry (names area Point <+>) (as G))
(type Color (params) (con Red) (con Green) (con Blue))
(type Point (params) (con-record _ (fields (field x U64) (field y U64))))
(type Tree (params a) (con Leaf) (con Node (app Tree a) a (app Tree a)))
(alias Weighted (params) (list (tuple U64 U64)))
(alias Pair (params a b) (tuple a b))
(extern-sig (names reset) (-> (unit) (unit)))
(extern-type Suspension (params a b r (row e)))
(class
  Eq
  (params a)
  (sig (names ==) (-> a (-> a Bool)))
  (sig (names /=) (-> a (-> a Bool)))
  (def-infix /= (params x y) (app not (infix x (== y)))))
(instance
  Eq
  (args Color)
  (def-infix == (params a b) (infix (app tag a) (== (app tag b)))))
(instance
  (ctx (app Eq a))
  Eq
  (args (app Tree a))
  (def-infix == (params a b) True))
(foreign
  Libc
  "c"
  (member strlen (-> (lend Bytes) U64))
  (member free (-> (own Bytes) (unit)))
  (member getenv (-> String (copy String)))
  (member puts "wok_puts" (-> String (unit))))
(effect Writer (params w) (op tell (-> w (unit))))
(sig (names <+>) (-> U64 (-> U64 U64)))
(def <+> (params a b) (infix a (+ b)))
(def-infix plus (params x y) (infix x (+ y)))
(def-infix ++ (params xs ys) (app concat xs ys))
(sig (names total) (=> (app Eq a) (-> (list U64) U64)))
(def total (params xs) (let-in (bind start 0) (app foldr (op +) start xs)))
(sig (names staged) U64)
(def
  staged
  (params)
  (block
    (let-in (bind n (block (app seed (unit)) (app bump 1))) (infix n (* 2)))))
(sig (names peek) (-> (app Suspension a b r (row-arg e)) a))
(def peek (params s) (app head s))
(sig (names shift) (-> (list U64) (list U64)))
(def shift (params ns) (app map (lam (params n) (infix n (- 1))) ns))
(sig (names pick) (-> Bool (-> U64 U64)))
(def
  pick
  (params loud n)
  (block (if loud (infix n (plus bump)) (neg n)))
  (where (def bump (params) 10)))
(sig (names origin) Point)
(def origin (params) (record Point (field x 0) (field y 0)))
(sig (names moveX) (-> Point (-> U64 Point)))
(def
  moveX
  (params p d)
  (record Point (.. p) (field x (infix (dot p x) (+ d)))))
(sig (names nameOf) (-> Point U64))
(def nameOf (params p) (case p (alt (precord Point (field x a) ..) a)))
(sig (names emptyish) (-> Point Bool))
(def
  emptyish
  (params p)
  (case p (alt (precord Point) True) (alt (precord Point ..rest) False)))
(sig (names firstTwo) (-> (list U64) (list U64)))
(def
  firstTwo
  (params xs)
  (case
    xs
    (alt (as (:: a (:: b _)) whole) whole)
    (alt (list 0) (list))
    (alt _ xs)))
(sig
  (names logging)
  (with
    (app Handler (app Writer (list String)) a a)
    (row (role log (app Writer (list String))))))
(def
  logging
  (params)
  (handler Writer (clause tell (args w) (app (dot log tell) w))))
(sig
  (names run)
  (with (-> (unit) U64) (row (role c (app State U64)) (eff e))))
(def
  run
  (params (unit))
  (block
    (use (as c (slot State)))
    (discard (app bumpAmbient (unit)))
    (let
      (bind doubled (block (let (bind n (dot State get))) (infix n (* 2)))))
    (app (dot State set) doubled)
    (dot State get)))
