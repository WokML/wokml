(W_File
    (seq
      (D_Module
        (N_ModPath
          (seq
            (N_Name "Borrow" #t))))
      (D_Import
        (N_ModPath
          (seq
            (N_Name "Base" #t)))
        (seq)
        (none))
      (D_ExternType
        "Borrow"
        (seq))
      (D_Sig
        (seq
          (H_SigName "length" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Borrow" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "byteAt" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Borrow" #t))))
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
          (H_SigName "slice" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Borrow" #t))))
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
                    (N_Name "Borrow" #t)))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "memchr" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Borrow" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_App
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "Option" #t))))
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "U64" #t)))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "copy" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Borrow" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "__borrow_demo" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Borrow" #t)))))
        #t)
      (D_Foreign
        "Demo"
        "\"wok\""
        (seq
          (H_ForeignMember
            "lendBuffer"
            ""
            (T_With
              (T_Fun
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "U64" #t))))
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "Borrow" #t)))))
              (seq
                (H_RowEntry
                  0
                  ""
                  (some
                    (T_Con
                      (N_ModPath
                        (seq
                          (N_Name "IO" #t)))))))))))))
