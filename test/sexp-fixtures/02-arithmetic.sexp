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
          (H_SigName "add" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))))
        #f)
      (D_Equation
        (L_Prefix
          "add"
          #f
          (seq
            (P_Var "x")
            (P_Var "y")))
        (E_Chain
          (E_Var "x")
          (seq
            (H_ChainOp
              "+"
              #f
              (E_Var "y"))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "double" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #f)
      (D_Equation
        (L_Prefix
          "double"
          #f
          (seq
            (P_Var "n")))
        (E_Chain
          (E_Var "n")
          (seq
            (H_ChainOp
              "*"
              #f
              (E_Int 2))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "quad" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #f)
      (D_Equation
        (L_Prefix
          "quad"
          #f
          (seq
            (P_Var "n")))
        (E_App
          (E_Var "double")
          (E_App
            (E_Var "double")
            (E_Var "n")))
        (seq))))
