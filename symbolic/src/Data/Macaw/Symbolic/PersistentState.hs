{-|
Copyright        : (c) Galois, Inc 2015-2017
Maintainer       : Joe Hendrix <jhendrix@galois.com>

This defines the monad used to map Reopt blocks to Crucible.
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# OPTIONS_GHC -Wwarn #-}
module Data.Macaw.Symbolic.PersistentState
  ( -- * CrucPersistentState
    CrucPersistentState(..)
  , initCrucPersistentState
    -- * Types
  , ToCrucibleBaseType
  , ToCrucibleType
  , CtxToCrucibleType
  , ArchRegContext
  , typeToCrucibleBase
  , typeToCrucible
  , typeCtxToCrucible
  , macawAssignToCrucM
  , memReprToCrucible
    -- * Register index map
  , RegIndexMap
  , mkRegIndexMap
  , IndexPair(..)
    -- * Values
  , MacawCrucibleValue(..)
  ) where

import qualified Data.Macaw.CFG as M
import qualified Data.Macaw.Types as M
import           Data.Parameterized.Classes
import           Data.Parameterized.Context
import qualified Data.Parameterized.List as P
import           Data.Parameterized.Map (MapF)
import qualified Data.Parameterized.Map as MapF
import           Data.Parameterized.TraversableF
import qualified Lang.Crucible.CFG.Reg as CR
import qualified Lang.Crucible.Types as C

------------------------------------------------------------------------
-- Type mappings

type family ToCrucibleBaseTypeList (l :: [M.Type]) :: Ctx C.BaseType where
  ToCrucibleBaseTypeList '[] = EmptyCtx
  ToCrucibleBaseTypeList (h ': l) = ToCrucibleBaseTypeList l ::> ToCrucibleBaseType h

type family ToCrucibleBaseType (mtp :: M.Type) :: C.BaseType where
  ToCrucibleBaseType M.BoolType   = C.BaseBoolType
  ToCrucibleBaseType (M.BVType w) = C.BaseBVType w
  ToCrucibleBaseType ('M.TupleType l) = C.BaseStructType (ToCrucibleBaseTypeList l)

type family CtxToCrucibleBaseType (mtp :: Ctx M.Type) :: Ctx C.BaseType where
  CtxToCrucibleBaseType EmptyCtx   = EmptyCtx
  CtxToCrucibleBaseType (c ::> tp) = CtxToCrucibleBaseType c ::> ToCrucibleBaseType tp

type ToCrucibleType tp = C.BaseToType (ToCrucibleBaseType tp)

type family CtxToCrucibleType (mtp :: Ctx M.Type) :: Ctx C.CrucibleType where
  CtxToCrucibleType EmptyCtx   = EmptyCtx
  CtxToCrucibleType (c ::> tp) = CtxToCrucibleType c ::> ToCrucibleType tp

-- | Create the variables from a collection of registers.
macawAssignToCruc :: (forall tp . f tp -> g (ToCrucibleType tp))
                  -> Assignment f ctx
                  -> Assignment g (CtxToCrucibleType ctx)
macawAssignToCruc f a =
  case a of
    Empty -> empty
    b :> x -> macawAssignToCruc f b :> f x

-- | Create the variables from a collection of registers.
macawAssignToCrucM :: Applicative m
                   => (forall tp . f tp -> m (g (ToCrucibleType tp)))
                   -> Assignment f ctx
                   -> m (Assignment g (CtxToCrucibleType ctx))
macawAssignToCrucM f a =
  case a of
    Empty -> pure empty
    b :> x -> (:>) <$> macawAssignToCrucM f b <*> f x

typeToCrucibleBase :: M.TypeRepr tp -> C.BaseTypeRepr (ToCrucibleBaseType tp)
typeToCrucibleBase tp =
  case tp of
    M.BoolTypeRepr  -> C.BaseBoolRepr
    M.BVTypeRepr w  -> C.BaseBVRepr w
    M.TupleTypeRepr a -> C.BaseStructRepr (typeListToCrucibleBase a)

typeListToCrucibleBase :: P.List M.TypeRepr ctx -> Assignment C.BaseTypeRepr (ToCrucibleBaseTypeList ctx)
typeListToCrucibleBase P.Nil = Empty
typeListToCrucibleBase (h P.:< r) = typeListToCrucibleBase r :> typeToCrucibleBase h

typeToCrucible :: M.TypeRepr tp -> C.TypeRepr (ToCrucibleType tp)
typeToCrucible = C.baseToType . typeToCrucibleBase

-- Return the types associated with a register assignment.
typeCtxToCrucible :: Assignment M.TypeRepr ctx
                  -> Assignment C.TypeRepr (CtxToCrucibleType ctx)
typeCtxToCrucible = macawAssignToCruc typeToCrucible

memReprToCrucible :: M.MemRepr tp -> C.TypeRepr (ToCrucibleType tp)
memReprToCrucible = typeToCrucible . M.typeRepr

------------------------------------------------------------------------
-- RegIndexMap

-- | Type family for architecture registers
type family ArchRegContext (arch :: *) :: Ctx M.Type

-- | This relates an index from macaw to Crucible.
data IndexPair ctx tp = IndexPair { macawIndex    :: !(Index ctx tp)
                                  , crucibleIndex :: !(Index (CtxToCrucibleType ctx) (ToCrucibleType tp))
                                  }

-- | This extends the indices in the pair.
extendIndexPair :: IndexPair ctx tp -> IndexPair (ctx::>utp) tp
extendIndexPair (IndexPair i j) = IndexPair (extendIndex i) (extendIndex j)


type RegIndexMap arch = MapF (M.ArchReg arch) (IndexPair (ArchRegContext arch))

mkRegIndexMap :: OrdF r
              => Assignment r ctx
              -> Size (CtxToCrucibleType ctx)
              -> MapF r (IndexPair ctx)
mkRegIndexMap Empty _ = MapF.empty
mkRegIndexMap (a :> r) csz =
  case viewSize csz of
    IncSize csz0 ->
      let m = fmapF extendIndexPair (mkRegIndexMap a csz0)
          idx = IndexPair (nextIndex (size a)) (nextIndex csz0)
       in MapF.insert r idx m

------------------------------------------------------------------------
-- Misc types

-- | A Crucible value with a Macaw type.
data MacawCrucibleValue f tp = MacawCrucibleValue (f (ToCrucibleType tp))

------------------------------------------------------------------------
-- CrucPersistentState

-- | State that needs to be persisted across block translations
data CrucPersistentState ids s
   = CrucPersistentState
   { valueCount :: !Int
     -- ^ Counter used to get fresh indices for Crucible atoms.
   , assignValueMap :: !(MapF (M.AssignId ids) (MacawCrucibleValue (CR.Atom s)))
     -- ^ Map Macaw assign id to associated Crucible value.
   }

-- | Initial crucible persistent state
initCrucPersistentState :: forall ids s . Int -> CrucPersistentState ids s
initCrucPersistentState argCount =
  CrucPersistentState
      { -- Count initial arguments in valie
        valueCount     = argCount
      , assignValueMap = MapF.empty
      }
