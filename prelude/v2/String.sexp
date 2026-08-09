(W_File
    (seq
      (D_Module
        (N_ModPath
          (seq
            (N_Name "String" #t))))
      (D_Import
        (N_ModPath
          (seq
            (N_Name "Base" #t)))
        (seq)
        (none))
      (D_Sig
        (seq
          (H_SigName "length" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
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
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Char" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "byteLength" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
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
                (N_Name "String" #t))))
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
          (H_SigName "append" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "indexOfFromRaw" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
            (T_Fun
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "U64" #t))))
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "U64" #t)))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "hash" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "editDistance" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
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
                (N_Name "String" #t))))
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
                    (N_Name "String" #t)))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "byteSlice" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
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
                    (N_Name "String" #t)))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "decodeCharAt" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Char" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "charWidthAt" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
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
          (H_SigName "singleton" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Char" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "notFound" #f))
        (T_Con
          (N_ModPath
            (seq
              (N_Name "U64" #t))))
        #f)
      (D_Equation
        (L_Prefix
          "notFound"
          #f
          (seq))
        (E_Int 18446744073709551615)
        (seq))
      (D_Sig
        (seq
          (H_SigName "indexOfFrom" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
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
                      (N_Name "U64" #t))))))))
        #f)
      (D_Equation
        (L_Prefix
          "indexOfFrom"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")
            (P_Var "from")))
        (E_Block
          (seq
            (S_Let
              (H_Bind
                (L_Prefix
                  "r"
                  #f
                  (seq))
                (E_App
                  (E_App
                    (E_App
                      (E_Var "indexOfFromRaw")
                      (E_Var "s"))
                    (E_Var "n"))
                  (E_Var "from"))))
            (E_Case
              (E_App
                (E_App
                  (E_Var "eqU64")
                  (E_Var "r"))
                (E_Var "notFound"))
              (seq
                (H_Alt
                  (P_Con
                    (N_ModPath
                      (seq
                        (N_Name "True" #t)))
                    (seq))
                  (E_Con "None")
                  (seq))
                (H_Alt
                  (P_Con
                    (N_ModPath
                      (seq
                        (N_Name "False" #t)))
                    (seq))
                  (E_App
                    (E_Con "Some")
                    (E_Var "r"))
                  (seq))))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "indexOf" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
            (T_App
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "Option" #t))))
              (T_Con
                (N_ModPath
                  (seq
                    (N_Name "U64" #t)))))))
        #f)
      (D_Equation
        (L_Prefix
          "indexOf"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")))
        (E_App
          (E_App
            (E_App
              (E_Var "indexOfFrom")
              (E_Var "s"))
            (E_Var "n"))
          (E_Int 0))
        (seq))
      (D_Sig
        (seq
          (H_SigName "contains" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))))
        #f)
      (D_Equation
        (L_Prefix
          "contains"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")))
        (E_Case
          (E_App
            (E_App
              (E_Var "indexOf")
              (E_Var "s"))
            (E_Var "n"))
          (seq
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "Some" #t)))
                (seq
                  (P_Wild)))
              (E_Con "True")
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "None" #t)))
                (seq))
              (E_Con "False")
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "take" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))))
        #f)
      (D_Equation
        (L_Prefix
          "take"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")))
        (E_App
          (E_App
            (E_App
              (E_Var "slice")
              (E_Var "s"))
            (E_Int 0))
          (E_Var "n"))
        (seq))
      (D_Sig
        (seq
          (H_SigName "drop" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))))
        #f)
      (D_Equation
        (L_Prefix
          "drop"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")))
        (E_App
          (E_App
            (E_App
              (E_Var "slice")
              (E_Var "s"))
            (E_Var "n"))
          (E_App
            (E_Var "length")
            (E_Var "s")))
        (seq))
      (D_Sig
        (seq
          (H_SigName "count" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U64" #t))))))
        #f)
      (D_Equation
        (L_Prefix
          "count"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")))
        (E_Case
          (E_App
            (E_App
              (E_Var "eqU64")
              (E_App
                (E_Var "byteLength")
                (E_Var "n")))
            (E_Int 0))
          (seq
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "True" #t)))
                (seq))
              (E_Int 0)
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "False" #t)))
                (seq))
              (E_App
                (E_App
                  (E_App
                    (E_App
                      (E_Var "countFrom")
                      (E_Var "s"))
                    (E_Var "n"))
                  (E_Int 0))
                (E_Int 0))
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "countFrom" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "String" #t))))
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
                      (N_Name "U64" #t))))))))
        #f)
      (D_Equation
        (L_Prefix
          "countFrom"
          #f
          (seq
            (P_Var "s")
            (P_Var "n")
            (P_Var "from")
            (P_Var "acc")))
        (E_Case
          (E_App
            (E_App
              (E_App
                (E_Var "indexOfFrom")
                (E_Var "s"))
              (E_Var "n"))
            (E_Var "from"))
          (seq
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "None" #t)))
                (seq))
              (E_Var "acc")
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "Some" #t)))
                (seq
                  (P_Var "i")))
              (E_App
                (E_App
                  (E_App
                    (E_App
                      (E_Var "countFrom")
                      (E_Var "s"))
                    (E_Var "n"))
                  (E_Chain
                    (E_Var "i")
                    (seq
                      (H_ChainOp
                        "+"
                        #f
                        (E_App
                          (E_Var "byteLength")
                          (E_Var "n"))))))
                (E_Chain
                  (E_Var "acc")
                  (seq
                    (H_ChainOp
                      "+"
                      #f
                      (E_Int 1)))))
              (seq))))
        (seq))
      (D_Sig
        (seq
          (H_SigName "foldChars" #f))
        (T_With
          (T_Fun
            (T_With
              (T_Fun
                (T_Var "s")
                (T_Fun
                  (T_Con
                    (N_ModPath
                      (seq
                        (N_Name "Char" #t))))
                  (T_Var "s")))
              (seq
                (H_RowEntry
                  2
                  "e"
                  (none))))
            (T_Fun
              (T_Var "s")
              (T_Fun
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "String" #t))))
                (T_Var "s"))))
          (seq
            (H_RowEntry
              2
              "e"
              (none))))
        #f)
      (D_Equation
        (L_Prefix
          "foldChars"
          #f
          (seq
            (P_Var "f")
            (P_Var "acc")
            (P_Var "str")))
        (E_App
          (E_App
            (E_App
              (E_App
                (E_App
                  (E_Var "foldCharsGo")
                  (E_Var "f"))
                (E_Var "acc"))
              (E_Var "str"))
            (E_Int 0))
          (E_App
            (E_Var "byteLength")
            (E_Var "str")))
        (seq))
      (D_Sig
        (seq
          (H_SigName "foldCharsGo" #f))
        (T_With
          (T_Fun
            (T_With
              (T_Fun
                (T_Var "s")
                (T_Fun
                  (T_Con
                    (N_ModPath
                      (seq
                        (N_Name "Char" #t))))
                  (T_Var "s")))
              (seq
                (H_RowEntry
                  2
                  "e"
                  (none))))
            (T_Fun
              (T_Var "s")
              (T_Fun
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "String" #t))))
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
                    (T_Var "s"))))))
          (seq
            (H_RowEntry
              2
              "e"
              (none))))
        #f)
      (D_Equation
        (L_Prefix
          "foldCharsGo"
          #f
          (seq
            (P_Var "f")
            (P_Var "acc")
            (P_Var "str")
            (P_Var "off")
            (P_Var "end")))
        (E_Block
          (seq
            (E_Case
              (E_App
                (E_App
                  (E_Var "eqU64")
                  (E_Var "off"))
                (E_Var "end"))
              (seq
                (H_Alt
                  (P_Con
                    (N_ModPath
                      (seq
                        (N_Name "True" #t)))
                    (seq))
                  (E_Var "acc")
                  (seq))
                (H_Alt
                  (P_Con
                    (N_ModPath
                      (seq
                        (N_Name "False" #t)))
                    (seq))
                  (E_App
                    (E_App
                      (E_App
                        (E_App
                          (E_App
                            (E_Var "foldCharsGo")
                            (E_Var "f"))
                          (E_App
                            (E_App
                              (E_Var "f")
                              (E_Var "acc"))
                            (E_App
                              (E_App
                                (E_Var "decodeCharAt")
                                (E_Var "str"))
                              (E_Var "off"))))
                        (E_Var "str"))
                      (E_Chain
                        (E_Var "off")
                        (seq
                          (H_ChainOp
                            "+"
                            #f
                            (E_App
                              (E_App
                                (E_Var "charWidthAt")
                                (E_Var "str"))
                              (E_Var "off"))))))
                    (E_Var "end"))
                  (seq))))))
        (seq))))
