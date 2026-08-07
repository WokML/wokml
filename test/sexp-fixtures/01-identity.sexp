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
          (H_SigName "myId" #f))
        (T_Fun
          (T_Var "a")
          (T_Var "a"))
        #f)
      (D_Equation
        (L_Prefix
          "myId"
          #f
          (seq
            (P_Var "x")))
        (E_Var "x")
        (seq))
      (D_Sig
        (seq
          (H_SigName "myConst" #f))
        (T_Fun
          (T_Var "a")
          (T_Fun
            (T_Var "b")
            (T_Var "a")))
        #f)
      (D_Equation
        (L_Prefix
          "myConst"
          #f
          (seq
            (P_Var "x")
            (P_Var "y")))
        (E_Var "x")
        (seq))
      (D_Sig
        (seq
          (H_SigName "myFlip" #f))
        (T_Fun
          (T_Fun
            (T_Var "a")
            (T_Fun
              (T_Var "b")
              (T_Var "c")))
          (T_Fun
            (T_Var "b")
            (T_Fun
              (T_Var "a")
              (T_Var "c"))))
        #f)
      (D_Equation
        (L_Prefix
          "myFlip"
          #f
          (seq
            (P_Var "f")
            (P_Var "x")
            (P_Var "y")))
        (E_App
          (E_App
            (E_Var "f")
            (E_Var "y"))
          (E_Var "x"))
        (seq))))
