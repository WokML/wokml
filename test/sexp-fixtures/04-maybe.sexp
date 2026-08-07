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
          (H_SigName "fromOption" #f))
        (T_Fun
          (T_Var "a")
          (T_Fun
            (T_App
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "Option" #t))))
              (T_Var "a"))
            (T_Var "a")))
        #f)
      (D_Equation
        (L_Prefix
          "fromOption"
          #f
          (seq
            (P_Var "d")
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
              (E_Var "d")
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "Some" #t)))
                (seq
                  (P_Var "x")))
              (E_Var "x")
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "mapOption" #f))
        (T_Fun
          (T_Fun
            (T_Var "a")
            (T_Var "b"))
          (T_Fun
            (T_App
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "Option" #t))))
              (T_Var "a"))
            (T_App
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "Option" #t))))
              (T_Var "b"))))
        #f)
      (D_Equation
        (L_Prefix
          "mapOption"
          #f
          (seq
            (P_Var "f")
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
              (E_Con "None")
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "Some" #t)))
                (seq
                  (P_Var "x")))
              (E_App
                (E_Con "Some")
                (E_App
                  (E_Var "f")
                  (E_Var "x")))
              (seq))))
        (seq))))
