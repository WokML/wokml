(W_File
    (seq
      (D_Module
        (N_ModPath
          (seq
            (N_Name "Main" #t))))
      (D_Import
        (N_ModPath
          (seq
            (N_Name "Base" #t)))
        (seq)
        (none))
      (D_Effect
        "State"
        (seq
          (H_TyParam "s" #f))
        (seq
          (H_OpSig
            "get"
            (T_Var "s"))
          (H_OpSig
            "set"
            (T_Fun
              (T_Var "s")
              (T_Unit)))))
      (D_Sig
        (seq
          (H_SigName "state" #f))
        (T_Fun
          (T_Var "s")
          (T_App
            (T_App
              (T_App
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "Handler" #t))))
                (T_App
                  (T_Con
                    (N_ModPath
                      (seq
                        (N_Name "State" #t))))
                  (T_Var "s")))
              (T_Var "a"))
            (T_Tuple
              (seq
                (T_Var "a")
                (T_Var "s")))))
        #f)
      (D_Equation
        (L_Prefix
          "state"
          #f
          (seq
            (P_Var "init")))
        (E_Handler
          "State"
          (seq
            (H_Clause
              3
              "cur"
              (seq)
              ""
              (E_Var "init"))
            (H_Clause
              0
              "get"
              (seq)
              ""
              (E_Var "cur"))
            (H_Clause
              0
              "set"
              (seq
                (P_Var "x"))
              ""
              (E_Assign
                (E_Var "cur")
                (E_Var "x")))
            (H_Clause
              2
              ""
              (seq
                (P_Var "v"))
              ""
              (E_Tuple
                (seq
                  (E_Var "v")
                  (E_Var "cur"))))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "sumList" #f))
        (T_With
          (T_Fun
            (T_List
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "U64" #t)))))
            (T_Unit))
          (seq
            (H_RowEntry
              1
              "st"
              (some
                (T_App
                  (T_Con
                    (N_ModPath
                      (seq
                        (N_Name "State" #t))))
                  (T_Con
                    (N_ModPath
                      (seq
                        (N_Name "U64" #t)))))))))
        #f)
      (D_Equation
        (L_Prefix
          "sumList"
          #f
          (seq
            (P_Var "xs")))
        (E_Case
          (E_Var "xs")
          (seq
            (H_Alt
              (P_List
                (seq))
              (E_Unit)
              (seq))
            (H_Alt
              (P_Cons
                (P_Var "y")
                (P_Var "ys"))
              (E_Block
                (seq
                  (E_App
                    (E_Dot
                      (E_Var "st")
                      "set"
                      #f)
                    (E_Chain
                      (E_Dot
                        (E_Var "st")
                        "get"
                        #f)
                      (seq
                        (H_ChainOp
                          "+"
                          #f
                          (E_Var "y")))))
                  (E_App
                    (E_Var "sumList")
                    (E_Var "ys"))))
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "main" #f))
        (T_Con
          (N_ModPath
            (seq
              (N_Name "U64" #t))))
        #f)
      (D_Equation
        (L_Prefix
          "main"
          #f
          (seq))
        (E_Block
          (seq
            (S_Let
              (H_Bind
                (P_Tuple
                  (seq
                    (P_Var "u")
                    (P_Var "total")))
                (E_HandleIn
                  "st"
                  (E_App
                    (E_Var "state")
                    (E_Int 0))
                  (E_App
                    (E_Var "sumList")
                    (E_List
                      (seq
                        (E_Int 3)
                        (E_Int 1)
                        (E_Int 4)
                        (E_Int 1)
                        (E_Int 5)
                        (E_Int 9)
                        (E_Int 2)
                        (E_Int 6)))))))
            (E_Var "total")))
        (seq))))
