(W_File
    (seq
      (D_Module
        (N_ModPath
          (seq
            (N_Name "Array" #t))))
      (D_Import
        (N_ModPath
          (seq
            (N_Name "Base" #t)))
        (seq)
        (none))
      (D_Sig
        (seq
          (H_SigName "new" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Fun
            (T_Var "a")
            (T_App
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "Array" #t))))
              (T_Var "a"))))
        #t)
      (D_Sig
        (seq
          (H_SigName "fromList" #f))
        (T_Fun
          (T_List
            (T_Var "a"))
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Array" #t))))
            (T_Var "a")))
        #t)
      (D_Sig
        (seq
          (H_SigName "toList" #f))
        (T_Fun
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Array" #t))))
            (T_Var "a"))
          (T_List
            (T_Var "a")))
        #t)
      (D_Sig
        (seq
          (H_SigName "index" #f))
        (T_Fun
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Array" #t))))
            (T_Var "a"))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Var "a")))
        #t)
      (D_Sig
        (seq
          (H_SigName "length" #f))
        (T_Fun
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Array" #t))))
            (T_Var "a"))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "set" #f))
        (T_Fun
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Array" #t))))
            (T_Var "a"))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Fun
              (T_Var "a")
              (T_App
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "Array" #t))))
                (T_Var "a")))))
        #t)
      (D_Sig
        (seq
          (H_SigName "resize" #f))
        (T_Fun
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Array" #t))))
            (T_Var "a"))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Fun
              (T_Var "a")
              (T_App
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "Array" #t))))
                (T_Var "a")))))
        #t)))
