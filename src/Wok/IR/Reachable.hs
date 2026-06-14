-- | Reachable-bind pruning over the typed Core/ANF module.
--
-- 'elaborateProgramFull' inlines the whole prelude; the RC interpreter
-- force-evaluates every value-CAF at load time, including dictionary CAFs that
-- bottom out in prims the RC store does not bind. Keeping only the binds
-- reachable from 'main' is a semantics-preserving dead-bind elimination (a bind
-- never reached from 'main' cannot influence its result) and lets the RC
-- interpreter run the first-order corpus cleanly.
--
-- This is the SINGLE source of truth shared by the @wok@ CLI
-- (@--dump-rc-stats@ / @--dump-perceus@) and the Suite A/B test harness, so the
-- bytes they produce cannot silently drift.
module Wok.IR.Reachable
  ( pruneToReachable
  , reachableBinds
  , bindReferencedUniques
  , exprUniques
  , firstOrderNoHandlerViolations
  , exprScopeFeatures
  ) where

import Data.List (find, nub)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Tx

import qualified Wok.IR.Anf as Anf
import qualified Wok.IR.Name as Name
import Wok.IR.Name (Unique)

-- | Semantics-preserving dead-bind elimination: keep only the binds reachable
-- from 'main' (preserving bind order). A bind never reached from 'main' cannot
-- influence main's result, so dropping it leaves observable behaviour unchanged.
pruneToReachable :: Anf.CoreModule -> Anf.CoreModule
pruneToReachable cm@(Anf.CoreModule binds) =
  let keep = Set.fromList (map (Name.nameUniq . Anf.tbName) (reachableBinds cm))
  in Anf.CoreModule
       [ tb | tb <- binds, Name.nameUniq (Anf.tbName tb) `Set.member` keep ]

-- | The set of top-level binds reachable from 'main' through the call graph
-- (variable references in bodies, treated as edges). Conservative: any
-- referenced 'Unique' that names a top-level bind is followed.
reachableBinds :: Anf.CoreModule -> [Anf.TopBind]
reachableBinds (Anf.CoreModule binds) =
  case find (\tb -> Name.nameHint (Anf.tbName tb) == Tx.pack "main") binds of
    Nothing       -> []   -- no main: nothing to reach
    Just mainBind ->
      let byUniq = Map.fromList [ (Name.nameUniq (Anf.tbName tb), tb) | tb <- binds ]
          go seen [] = seen
          go seen (u : rest)
            | u `Set.member` seen = go seen rest
            | otherwise =
                case Map.lookup u byUniq of
                  Nothing -> go seen rest   -- a local/prim Unique, not a bind
                  Just tb ->
                    let refs  = bindReferencedUniques tb
                        seen' = Set.insert u seen
                    in go seen' (Set.toList refs ++ rest)
          reached = go Set.empty [Name.nameUniq (Anf.tbName mainBind)]
      in [ tb | tb <- binds, Name.nameUniq (Anf.tbName tb) `Set.member` reached ]

-- | Every 'Unique' that appears as a variable reference inside a bind's body.
bindReferencedUniques :: Anf.TopBind -> Set.Set Unique
bindReferencedUniques tb = exprUniques (Anf.tbBody tb)

-- | Every 'Unique' appearing as a variable reference anywhere in an expression.
-- Binder introductions are included too; they cannot create spurious bind edges
-- because top-level bind Uniques are globally unique.
exprUniques :: Anf.Expr -> Set.Set Unique
exprUniques = goE
  where
    av (Anf.AVar n) = Set.singleton (Name.nameUniq n)
    av (Anf.ALit _) = Set.empty
    avs = Set.unions . map av
    goR r = case r of
      Anf.RAtom a          -> av a
      Anf.RApp f xs        -> Set.union (av f) (avs xs)
      Anf.RCon _ xs        -> avs xs
      Anf.RLam _ e         -> goE e
      Anf.ROp minst _ _ xs -> Set.union (maybe Set.empty av minst) (avs xs)
      Anf.RRecord _ flds   -> avs (map snd flds)
      Anf.RProj _ a        -> av a
    goA a = case a of
      Anf.AltCon _ _ e -> goE e
      Anf.AltLit _ e   -> goE e
      Anf.AltDefault e -> goE e
    goE e = case e of
      Anf.Ret a               -> av a
      Anf.Let _ r body        -> Set.union (goR r) (goE body)
      Anf.LetRec defs body    -> Set.unions (goE body : [ goE d | (_, _, d) <- defs ])
      Anf.Case a alts         -> Set.union (av a) (Set.unions (map goA alts))
      Anf.LetJoin _ _ jb body -> Set.union (goE jb) (goE body)
      Anf.Jump _ xs           -> avs xs
      Anf.Handle inner h      ->
        Set.union (goE inner)
          (Set.unions
             ( goE (snd (Anf.hReturn h))
             : [ goE (Anf.oaBody op) | op <- Anf.hOps h ] ))

-- | M1 scope guard. Returns a (possibly empty) list of human-readable
-- violations: a program is in scope for the RC interpreter iff every top-level
-- bind REACHABLE FROM 'main' is first-order (no 'RLam') and handler-free (no
-- 'Handle'/'ROp'). M1 supports only that fragment; higher-order closures and
-- effect handlers are deferred to M1.5. Scoping the check to the reachable call
-- graph (not the whole elaborated module) is deliberate: 'elaborateProgramFull'
-- inlines the entire prelude (which DOES contain handlers and lambdas), but none
-- of it is reached by a first-order corpus 'main', so it never executes on the
-- RC store.
firstOrderNoHandlerViolations :: Anf.CoreModule -> [Text]
firstOrderNoHandlerViolations cm =
  [ describe tb feature
  | tb <- reachableBinds cm
  , feature <- exprScopeFeatures (Anf.tbBody tb)
  ]
  where
    describe tb feature =
      Tx.pack "  bind '" <> Name.nameHint (Anf.tbName tb)
        <> Tx.pack "' uses " <> feature

-- | Out-of-scope features used directly in an expression: 'RLam' (first-class
-- closure), 'Handle' (effect handler), 'ROp' (effect operation). Returns a
-- de-duplicated list of feature names.
exprScopeFeatures :: Anf.Expr -> [Text]
exprScopeFeatures e = nub (go e)
  where
    rhs r = case r of
      Anf.RLam _ b         -> Tx.pack "RLam (first-class closure / HOF)" : go b
      Anf.ROp{}            -> [Tx.pack "ROp (effect operation)"]
      Anf.RApp _ _         -> []
      Anf.RAtom _          -> []
      Anf.RCon _ _         -> []
      Anf.RRecord _ _      -> []
      Anf.RProj _ _        -> []
    alt a = case a of
      Anf.AltCon _ _ b -> go b
      Anf.AltLit _ b   -> go b
      Anf.AltDefault b -> go b
    go x = case x of
      Anf.Ret _               -> []
      Anf.Let _ r body        -> rhs r ++ go body
      Anf.LetRec defs body    -> concat [ go d | (_, _, d) <- defs ] ++ go body
      Anf.Case _ alts         -> concatMap alt alts
      Anf.LetJoin _ _ jb body -> go jb ++ go body
      Anf.Jump _ _            -> []
      Anf.Handle _ _          -> [Tx.pack "Handle (effect handler)"]
