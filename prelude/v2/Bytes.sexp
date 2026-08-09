(W_File
    (seq
      (D_Module
        (N_ModPath
          (seq
            (N_Name "Bytes" #t))))
      (D_Import
        (N_ModPath
          (seq
            (N_Name "Base" #t)))
        (seq)
        (none))
      (D_Sig
        (seq
          (H_SigName "fromList" #f))
        (T_Fun
          (T_List
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t)))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "toList" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t))))
          (T_List
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "length" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "index" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "fromBytes" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t))))
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Option" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "toBytes" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "__ffi_demo_copy" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "__ffi_demo_adopt" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t)))))
        #t)))
