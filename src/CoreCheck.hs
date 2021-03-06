{-# LANGUAGE OverloadedStrings, ViewPatterns #-}
module CoreCheck(
  coreCheck
)
where

import Core
import Prim
import Type
import Utils

import Control.Monad.Except
import Data.Monoid

import qualified Data.Text as T

-- | Returns 'Right' if type-correct.
-- should this take a 'DeclEnv' too (containing data type decls?)
coreCheck :: KindEnv -> TypeEnv -> Expr -> Except T.Text Type
coreCheck kenv tenv = go . unFix
  where
    go (Var v  ) = maybe (throwError ("No type for variable: " <> tshow v)) return $ lookupTypeEnv tenv v
    go (App f x') = do
                   tf  <- go (unFix f)
                   coreCheckApp kenv tenv tf x'
    go (Abs tx x b) = coreCheck kenv (extendTypeEnv tenv x tx) b
    go (TyApp f t) = do
                   tf <- go       (unFix f)
                   k' <- typeKind kenv t
                   case unFix tf of
                     TForAll k tv tres -> do
                                       unless (k == k') $
                                              throwError $ "Attempt to type-apply a " <> tshow k
                                                             <> " to " <> tshow k'
                                       return $ tsubst tv t tres
                     _              -> throwError ("Attempt to type-apply a non-typeabs: " <> tshow f <> " :: " <> tshow tf)
    go (TyAbs k tb b)  = coreCheck (extendKindEnv kenv tb k) tenv b




    go (Lit l)         = return $ typeLit l
    go (Prim1 p x')    = coreCheckApp kenv tenv (primTy1 p) x'
    go (Prim2 p x' y') = coreCheckApp kenv tenv (primTy2 p) (Fix $ Tuple [x', y'])
    go (Tuple ts)      = Fix . TTuple <$> mapM (coreCheck kenv tenv) ts


coreCheckApp :: KindEnv -> TypeEnv -> Type -> Expr -> Except T.Text Type
coreCheckApp kenv tenv (Fix (TFunTy tx tres)) x' = do
                                       tx' <- coreCheck kenv tenv x'
                                       unless (tx == tx') $
                                              throwError $ "Attempt to apply fn expecting " <> tshow tx
                                                             <> " to " <> tshow tx'
                                       return tres
coreCheckApp _    _    tf _ = throwError ("Attempt to apply a non-function :: " <> tshow tf)


-- TODO
typeKind :: KindEnv -> Type -> Except T.Text Kind
typeKind _ _ = return ()

-- | TyVar substitution within a Type. eg
--
--   > tsubst tv t2 t
--
--   ... substitutes all occurences of 'tv' for 't2' in 't'.
tsubst :: TyVar -> Type -> Type -> Type
tsubst _ _ _ = error "TODO Review and Fixup 'tsubst' - It's at least broken when eg substituting something which has 'X' free under a binder which binds 'X' - it'll get accidentally captured ... so we need to do some alpha renaming or something (eg ensure global uniqueness of vars or whatever)."
tsubst tv t2 t@(Fix (TVar tv'))         | tv == tv' = t2
                                        | otherwise = t
tsubst tv t2   (Fix (TApp   t3 t4))                 = Fix $ TApp    (tsubst tv t2 t3) (tsubst tv t2 t4)
tsubst tv t2   (Fix (TFunTy t3 t4))                 = Fix $ TFunTy  (tsubst tv t2 t3) (tsubst tv t2 t4)
tsubst tv t2 t@(Fix (TForAll k tv' t3)) | tv == tv' = t
                                        | otherwise = Fix $ TForAll k tv' (tsubst tv t2 t3)
tsubst  _  _ t@(Fix (TCon _))                       = t
tsubst tv t2   (Fix (TTuple ts))                    = Fix $ TTuple $ map (tsubst tv t2) ts
tsubst tv t2   (Fix (TLet tv' t3 t4))   | tv == tv' = Fix $ TLet tv' (tsubst tv t2 t3) t4 -- NB Let is non recursive
                                        | otherwise = Fix $ TLet tv' (tsubst tv t2 t3) (tsubst tv t2 t4)
tsubst tv t2 t@(Fix (TLetRec tvts t4))  | any ((==tv) . fst) tvts = t -- The subst will not affect this
                                        | otherwise = Fix $ TLetRec (map (second $ tsubst tv t2) tvts)
                                                                    (tsubst tv t2 t4)

