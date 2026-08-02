(module Main)
(import Base)
(import Control)
(type Cmd (params) (con Inc U64) (con Snapshot) (con Boom))
(sig
  (names tick)
  (with
    (-> Cmd U64)
    (row
      (slot (app Reader U64))
      (slot (app Writer (list U64)))
      (slot (app State U64))
      (slot (app Except String)))))
(def
  tick
  (params cmd)
  (case
    cmd
    (alt
      (pcon Inc n)
      (block
        (app
          (dot State set)
          (infix (dot State get) (+ (dot Reader ask)) (* n)))
        1))
    (alt
      (pcon Snapshot)
      (block (app (dot Writer tell) (list (dot State get))) 1))
    (alt (pcon Boom) (app (dot Except throw) "machine hit a Boom"))))
(sig
  (names walk)
  (with
    (-> (list Cmd) U64)
    (row
      (slot (app Reader U64))
      (slot (app Writer (list U64)))
      (slot (app State U64))
      (slot (app Except String)))))
(def
  walk
  (params cmds)
  (case
    cmds
    (alt (list) 0)
    (alt (:: cmd rest) (infix (app tick cmd) (+ (app walk rest))))))
(sig (names main) (app Result (tuple (tuple U64 U64) (list U64)) String))
(def
  main
  (params)
  (block
    (handle (slot Except) except)
    (handle (slot Reader) (app reader 10))
    (handle (slot Writer) writer)
    (handle (slot State) (app state 0))
    (app walk (list (app Inc 1) Snapshot (app Inc 2) Snapshot))))
