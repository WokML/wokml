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
          (H_SigName "twice" #f))
        (T_Fun
          (T_Fun
            (T_Var "a")
            (T_Var "a"))
          (T_Fun
            (T_Var "a")
            (T_Var "a")))
        #f)
      (D_Equation
        (L_Prefix
          "twice"
          #f
          (seq
            (P_Var "f")
            (P_Var "x")))
        (E_App
          (E_Var "f")
          (E_App
            (E_Var "f")
            (E_Var "x")))
        (seq))
      (D_Sig
        (seq
          (H_SigName "compose" #f))
        (T_Fun
          (T_Fun
            (T_Var "b")
            (T_Var "c"))
          (T_Fun
            (T_Fun
              (T_Var "a")
              (T_Var "b"))
            (T_Fun
              (T_Var "a")
              (T_Var "c"))))
        #f)
      (D_Equation
        (L_Prefix
          "compose"
          #f
          (seq
            (P_Var "f")
            (P_Var "g")
            (P_Var "x")))
        (E_App
          (E_Var "f")
          (E_App
            (E_Var "g")
            (E_Var "x")))
        (seq))
      (D_Sig
        (seq
          (H_SigName "apply" #f))
        (T_Fun
          (T_Fun
            (T_Var "a")
            (T_Var "b"))
          (T_Fun
            (T_Var "a")
            (T_Var "b")))
        #f)
      (D_Equation
        (L_Prefix
          "apply"
          #f
          (seq
            (P_Var "f")
            (P_Var "x")))
        (E_App
          (E_Var "f")
          (E_Var "x"))
        (seq))))
