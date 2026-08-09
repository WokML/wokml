(W_File
    (seq
      (D_Module
        (N_ModPath
          (seq
            (N_Name "Base" #t))))
      (D_Fixity
        "+"
        #f
        0
        (seq))
      (D_Fixity
        "-"
        #f
        0
        (seq))
      (D_Fixity
        "*"
        #f
        0
        (seq
          (H_FixRel 0 "+" #f)))
      (D_Fixity
        "/"
        #f
        0
        (seq
          (H_FixRel 0 "+" #f)))
      (D_Fixity
        "=="
        #f
        0
        (seq
          (H_FixRel 1 "+" #f)))
      (D_Fixity
        "/="
        #f
        0
        (seq
          (H_FixRel 1 "+" #f)))
      (D_Fixity
        "&&"
        #f
        0
        (seq
          (H_FixRel 1 "==" #f)))
      (D_Fixity
        "||"
        #f
        0
        (seq
          (H_FixRel 1 "&&" #f)))
      (D_Fixity
        "++"
        #f
        1
        (seq))
      (D_Fixity
        "$"
        #f
        1
        (seq
          (H_FixRel 1 "||" #f)))
      (D_Type
        "Bool"
        (seq)
        (seq
          (H_ConDef
            "True"
            (seq)
            (seq)
            #f)
          (H_ConDef
            "False"
            (seq)
            (seq)
            #f)))
      (D_Type
        "Option"
        (seq
          (H_TyParam "a" #f))
        (seq
          (H_ConDef
            "Some"
            (seq
              (T_Var "a"))
            (seq)
            #f)
          (H_ConDef
            "None"
            (seq)
            (seq)
            #f)))
      (D_Type
        "Result"
        (seq
          (H_TyParam "t" #f)
          (H_TyParam "e" #f))
        (seq
          (H_ConDef
            "Ok"
            (seq
              (T_Var "t"))
            (seq)
            #f)
          (H_ConDef
            "Err"
            (seq
              (T_Var "e"))
            (seq)
            #f)))
      (D_Sig
        (seq
          (H_SigName "+" #t))
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
        #t)
      (D_Sig
        (seq
          (H_SigName "-" #t))
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
        #t)
      (D_Sig
        (seq
          (H_SigName "*" #t))
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
        #t)
      (D_Sig
        (seq
          (H_SigName "/" #t))
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
        #t)
      (D_Sig
        (seq
          (H_SigName "div" #f))
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
        #t)
      (D_Sig
        (seq
          (H_SigName "mod" #f))
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
        #t)
      (D_Sig
        (seq
          (H_SigName "&&" #t))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bool" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "||" #t))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bool" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "++" #t))
        (T_Fun
          (T_List
            (T_Var "a"))
          (T_Fun
            (T_List
              (T_Var "a"))
            (T_List
              (T_Var "a"))))
        #t)
      (D_Sig
        (seq
          (H_SigName "$" #t))
        (T_Fun
          (T_Fun
            (T_Var "a")
            (T_Var "b"))
          (T_Fun
            (T_Var "a")
            (T_Var "b")))
        #t)
      (D_Sig
        (seq
          (H_SigName "id" #f))
        (T_Fun
          (T_Var "a")
          (T_Var "a"))
        #f)
      (D_Equation
        (L_Prefix
          "id"
          #f
          (seq
            (P_Var "x")))
        (E_Var "x")
        (seq))
      (D_Sig
        (seq
          (H_SigName "const" #f))
        (T_Fun
          (T_Var "a")
          (T_Fun
            (T_Var "b")
            (T_Var "a")))
        #f)
      (D_Equation
        (L_Prefix
          "const"
          #f
          (seq
            (P_Var "x")
            (P_Var "y")))
        (E_Var "x")
        (seq))
      (D_Sig
        (seq
          (H_SigName "eqU64" #f))
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
                  (N_Name "Bool" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "eqU32" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U32" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "U32" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))))
        #t)
      (D_Sig
        (seq
          (H_SigName "u32" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U32" #t)))))
        #t)
      (D_Sig
        (seq
          (H_SigName "not" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bool" #t))))
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bool" #t)))))
        #f)
      (D_Equation
        (L_Prefix
          "not"
          #f
          (seq
            (P_Var "x")))
        (E_Case
          (E_Var "x")
          (seq
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "True" #t)))
                (seq))
              (E_Con "False")
              (seq))
            (H_Alt
              (P_Con
                (N_ModPath
                  (seq
                    (N_Name "False" #t)))
                (seq))
              (E_Con "True")
              (seq))))
        (seq))
      (D_Class
        "Eq"
        (seq
          (H_TyParam "a" #f))
        (seq
          (D_Sig
            (seq
              (H_SigName "==" #t))
            (T_Fun
              (T_Var "a")
              (T_Fun
                (T_Var "a")
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "Bool" #t))))))
            #f)
          (D_Sig
            (seq
              (H_SigName "/=" #t))
            (T_Fun
              (T_Var "a")
              (T_Fun
                (T_Var "a")
                (T_Con
                  (N_ModPath
                    (seq
                      (N_Name "Bool" #t))))))
            #f)
          (D_Equation
            (L_Prefix
              "/="
              #t
              (seq
                (P_Var "x")
                (P_Var "y")))
            (E_App
              (E_Var "not")
              (E_Chain
                (E_Var "x")
                (seq
                  (H_ChainOp
                    "=="
                    #f
                    (E_Var "y")))))
            (seq))))
      (D_Instance
        (none)
        "Eq"
        (seq
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U64" #t)))))
        (seq
          (D_Equation
            (L_Prefix
              "=="
              #t
              (seq))
            (E_Var "eqU64")
            (seq))))
      (D_Instance
        (none)
        "Eq"
        (seq
          (T_Con
            (N_ModPath
              (seq
                (N_Name "U32" #t)))))
        (seq
          (D_Equation
            (L_Prefix
              "=="
              #t
              (seq))
            (E_Var "eqU32")
            (seq))))
      (D_Instance
        (some
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Eq" #t))))
            (T_Var "a")))
        "Eq"
        (seq
          (T_App
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Option" #t))))
            (T_Var "a")))
        (seq
          (D_Equation
            (L_Prefix
              "=="
              #t
              (seq
                (P_Var "x")
                (P_Var "y")))
            (E_Block
              (seq
                (E_Case
                  (E_Var "x")
                  (seq
                    (H_Alt
                      (P_Con
                        (N_ModPath
                          (seq
                            (N_Name "None" #t)))
                        (seq))
                      (E_Case
                        (E_Var "y")
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
                    (H_Alt
                      (P_Con
                        (N_ModPath
                          (seq
                            (N_Name "Some" #t)))
                        (seq
                          (P_Var "a")))
                      (E_Case
                        (E_Var "y")
                        (seq
                          (H_Alt
                            (P_Con
                              (N_ModPath
                                (seq
                                  (N_Name "None" #t)))
                              (seq))
                            (E_Con "False")
                            (seq))
                          (H_Alt
                            (P_Con
                              (N_ModPath
                                (seq
                                  (N_Name "Some" #t)))
                              (seq
                                (P_Var "b")))
                            (E_Chain
                              (E_Var "a")
                              (seq
                                (H_ChainOp
                                  "=="
                                  #f
                                  (E_Var "b"))))
                            (seq))))
                      (seq))))))
            (seq))))
      (D_Sig
        (seq
          (H_SigName "eqString" #f))
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
        #t)
      (D_Instance
        (none)
        "Eq"
        (seq
          (T_Con
            (N_ModPath
              (seq
                (N_Name "String" #t)))))
        (seq
          (D_Equation
            (L_Prefix
              "=="
              #t
              (seq))
            (E_Var "eqString")
            (seq))))
      (D_Sig
        (seq
          (H_SigName "eqBytes" #f))
        (T_Fun
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t))))
          (T_Fun
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bytes" #t))))
            (T_Con
              (N_ModPath
                (seq
                  (N_Name "Bool" #t))))))
        #t)
      (D_Instance
        (none)
        "Eq"
        (seq
          (T_Con
            (N_ModPath
              (seq
                (N_Name "Bytes" #t)))))
        (seq
          (D_Equation
            (L_Prefix
              "=="
              #t
              (seq))
            (E_Var "eqBytes")
            (seq))))))
