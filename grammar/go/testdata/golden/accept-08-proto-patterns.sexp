(module Main)
(import Base)
(type Msg (params) (con Ping U64) (con Close))
(type Reply (params) (con Pong U64) (con Bye))
(effect Proto (params) (op req (-> Msg Reply)))
(sig (names server) (app Handler Proto a a))
(def
  server
  (params)
  (handler
    Proto
    (once req (args (pcon Ping n)) (k k) (app k (app Pong n)))
    (once req (args (pcon Close)) (k k) (app k Bye))))
(sig (names client) (with (-> (unit) U64) (row (slot Proto))))
(def
  client
  (params (unit))
  (case
    (app (dot Proto req) (app Ping 41))
    (alt (pcon Pong n) (infix n (+ 1)))
    (alt (pcon Bye) 0)))
(sig (names main) U64)
(def main (params) (handle-in (elided) server (app client (unit))))
