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
      (D_Sig
        (seq
          (H_SigName "first" #f))
        (T_Fun
          (T_Tuple
            (seq
              (T_Var "a")
              (T_Var "b")))
          (T_Var "a"))
        #f)
      (D_Equation
        (L_Prefix
          "first"
          #f
          (seq
            (P_Var "p")))
        (E_Case
          (E_Var "p")
          (seq
            (H_Alt
              (P_Tuple
                (seq
                  (P_Var "x")
                  (P_Wild)))
              (E_Var "x")
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "isNone" #f))
        (T_Fun
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Option" #t))))
            (T_Var "a"))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bool" #t)))))
        #f)
      (D_Equation
        (L_Prefix
          "isNone"
          #f
          (seq
            (P_Var "m")))
        (E_Case
          (E_Var "m")
          (seq
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "None" #t)))
                (seq))
              (E_Con "True")
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "Some" #t)))
                (seq
                  (P_Wild)))
              (E_Con "False")
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "headOr" #f))
        (T_Fun
          (T_Var "a")
          (T_Fun
            (T_List
              (T_Var "a"))
            (T_Var "a")))
        #f)
      (D_Equation
        (L_Prefix
          "headOr"
          #f
          (seq
            (P_Var "d")
            (P_Var "xs")))
        (E_Case
          (E_Var "xs")
          (seq
            (H_Alt
              (P_List
                (seq))
              (E_Var "d")
              (seq))
            (H_Alt
              (P_Cons
                (P_Var "x")
                (P_Wild))
              (E_Var "x")
              (seq))))
        (seq))))
