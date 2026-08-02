(module Main)
(import Base)
(type Msg (params) (con Ping U64) (con Close))
(effect Proto (params) (op req (-> Msg U64)))
(sig (names partial) (app Handler Proto a a))
(def
  partial
  (params)
  (handler Proto (once req (args (pcon Ping n)) (k k) (app k n))))
(sig (names main) U64)
(def main (params) (handle-in (elided) partial (app (dot Proto req) Close)))
