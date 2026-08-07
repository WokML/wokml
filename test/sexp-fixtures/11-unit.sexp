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
          (H_SigName "unit" #f))
        (T_Unit)
        #f)
      (D_Equation
        (L_Prefix
          "unit"
          #f
          (seq))
        (E_Unit)
        (seq))
      (D_Sig
        (seq
          (H_SigName "unitWs" #f))
        (T_Unit)
        #f)
      (D_Equation
        (L_Prefix
          "unitWs"
          #f
          (seq))
        (E_Unit)
        (seq))
      (D_Sig
        (seq
          (H_SigName "discard" #f))
        (T_Fun
          (T_Unit)
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #f)
      (D_Equation
        (L_Prefix
          "discard"
          #f
          (seq
            (P_Unit)))
        (E_Int 0)
        (seq))
      (D_Sig
        (seq
          (H_SigName "pairUU" #f))
        (T_Tuple
          (seq
            (T_Unit)
            (T_Unit)))
        #f)
      (D_Equation
        (L_Prefix
          "pairUU"
          #f
          (seq))
        (E_Tuple
          (seq
            (E_Unit)
            (E_Unit)))
        (seq))))
