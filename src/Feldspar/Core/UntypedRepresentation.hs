{-# LANGUAGE DeriveLift #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wall #-}
-- Names shadow in this module, not a big deal.
{-# OPTIONS_GHC -Wno-name-shadowing #-}
-- FIXME: Partial functions.
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
-- Unknown severity.
{-# OPTIONS_GHC -Wno-type-defaults #-}

--
-- Copyright (c) 2019, ERICSSON AB
-- All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions are met:
--
--     * Redistributions of source code must retain the above copyright notice,
--       this list of conditions and the following disclaimer.
--     * Redistributions in binary form must reproduce the above copyright
--       notice, this list of conditions and the following disclaimer in the
--       documentation and/or other materials provided with the distribution.
--     * Neither the name of the ERICSSON AB nor the names of its contributors
--       may be used to endorse or promote products derived from this software
--       without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
-- IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
-- DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
-- FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
-- DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
-- SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
-- CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
-- OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
-- OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
--

module Feldspar.Core.UntypedRepresentation (
    VarId (..)
  , Term(..)
  , AUntypedFeld
  , UntypedFeldF(..)
  , Op(..)
  , ScalarType(..)
  , Type(..)
  , Lit(..)
  , Var(..)
  , Size(..)
  , Signedness(..)
  , Fork(..)
  , HasType(..)
  , getAnnotation
  , dropAnnotation
  , fv
  , collectLetBinders
  , collectBinders
  , mkLets
  , mkLam
  , mkApp
  , mkTup
  , subst
  , stringTree
  , stringTreeExp
  , prettyExp
  , indexType
  , sharable
  , legalToShare
  , goodToShare
  , legalToInline
  , Rename
  , rename
  , newVar
  )
  where

import Control.Monad.State hiding (join)
import qualified Data.Map.Strict as M
import qualified Data.ByteString.Char8 as B
import Data.Function (on)
import Data.List (nubBy, intercalate)
import Data.Tree
import Language.Haskell.TH.Syntax (Lift(..))

import Feldspar.Core.Representation (VarId(..))

import Feldspar.Range (Range(..), singletonRange)
import Feldspar.Core.Types (Length)

-- This file contains the UntypedFeld format and associated
-- helper-formats and -functions that work on those formats, for
-- example fv and typeof.
--
-- The format resembles the structure of the typed Syntactic format,
-- but it does not reflect into the host language type system.

-- | Types representing an annotated term
type AUntypedFeld a = Term a UntypedFeldF

data Term a f = AIn a (f (Term a f))

deriving instance (Eq a, Eq (f (Term a f))) => Eq (Term a f)
instance (Show (f (Term a f))) => Show (Term a f) where
  show (AIn _ f) = show f

-- | Extract the annotation part of an AUntypedFeld
getAnnotation :: AUntypedFeld a -> a
getAnnotation (AIn r _) = r

-- | Drop the annotation part of an AUntypedFeld
dropAnnotation :: AUntypedFeld a -> UntypedFeldF (AUntypedFeld a)
dropAnnotation (AIn _ e) = e

data Size = S8 | S16 | S32 | S40 | S64
          | S128 -- Used by SICS.
    deriving (Eq,Show,Enum,Ord,Lift)

data Signedness = Signed | Unsigned
    deriving (Eq,Show,Enum,Lift)

data Fork = None | Future | Par | Loop
    deriving (Eq,Show)

data ScalarType =
     BoolType
   | BitType
   | IntType Signedness Size
   | FloatType
   | DoubleType
   | ComplexType Type
   deriving (Eq,Show)

data Type =
     Length :# ScalarType
   | StringType
   | TupType [Type]
   | MutType Type
   | RefType Type
   | ArrayType (Range Length) Type
   | MArrType (Range Length) Type
   | ParType Type
   | ElementsType Type
   | IVarType Type
   | FunType Type Type
   | FValType Type
   deriving (Eq,Show)

data Var = Var { varNum :: VarId
               , varType :: Type
               , varName :: B.ByteString
               }

-- Variables are equal if they have the same varNum.
instance Eq Var where
  v1 == v2 = varNum v1 == varNum v2

instance Ord Var where
  compare v1 v2 = compare (varNum v1) (varNum v2)

instance Show Var where
  show (Var n _t name) = (if name == B.empty
                            then "v"
                            else B.unpack name) ++ show n

data Lit =
     LBool Bool
   | LInt Signedness Size Integer
   | LFloat Float
   | LDouble Double
   | LComplex Lit Lit
   | LString String -- String value including quotes if required.
   | LArray Type [Lit] -- Type necessary for empty array literals.
   | LTup [Lit]
   deriving (Eq)

-- | The Type used to represent indexes, to which Index is mapped.
indexType :: Type
indexType = 1 :# IntType Unsigned S32

-- | Human readable show instance.
instance Show Lit where
   show (LBool b)                    = show b
   show (LInt _ _ i)                 = show i
   show (LFloat f)                   = show f
   show (LDouble d)                  = show d
   show (LComplex r c)               = "(" ++ show r ++ ", " ++ show c ++ "i)"
   show (LString s)                  = s
   show (LArray _ ls)                = "[" ++ sls ++ "]"
     where sls = intercalate "," $ map show ls
   show (LTup ls)                    = "(" ++ intercalate ", " (map show ls) ++ ")"

-- | Application heads.
data Op =
   -- Array
     GetLength
   | Parallel
   | Append
   | GetIx
   | SetLength
   | Sequential
   | SetIx
   -- Binding
   | Let
   -- Bits
   | Bit
   | Complement
   | ReverseBits
   | BitScan
   | BitCount
   | BAnd
   | BOr
   | BXor
   | SetBit
   | ClearBit
   | ComplementBit
   | TestBit
   | ShiftLU
   | ShiftRU
   | ShiftL
   | ShiftR
   | RotateLU
   | RotateRU
   | RotateL
   | RotateR
   -- Complex
   | RealPart
   | ImagPart
   | Conjugate
   | Magnitude
   | Phase
   | Cis
   | MkComplex
   | MkPolar
   -- Condition
   | Condition
   | ConditionM
   -- Conversion
   | F2I
   | I2N
   | B2I
   | Round
   | Ceiling
   | Floor
   -- Elements
   | ESkip
   | EMaterialize
   | EWrite
   | EPar
   | EparFor
   -- Eq
   | Equal
   | NotEqual
   -- Error
   | Undefined
   | Assert String
   -- FFI
   | ForeignImport String
   -- Floating
   | Exp
   | Sqrt
   | Log
   | Sin
   | Tan
   | Cos
   | Asin
   | Atan
   | Acos
   | Sinh
   | Tanh
   | Cosh
   | Asinh
   | Atanh
   | Acosh
   | Pow
   | LogBase
   -- Floating
   | Pi
   -- Fractional
   | DivFrac
   -- Future
   | MkFuture
   | Await
   -- Integral
   | Quot
   | Rem
   | Div
   | Mod
   | IExp
   -- Logic
   | Not
   -- Logic
   | And
   | Or
   -- Loop
   | ForLoop
   | WhileLoop
   -- LoopM
   | While
   | For
   -- Mutable
   | Run
   | Return
   | Bind
   | Then
   | When
   -- MutableArray
   | NewArr_
   | ArrLength
   | NewArr
   | GetArr
   | SetArr
   -- MutableToPure
   | RunMutableArray
   | WithArray
   -- MutableReference
   | NewRef
   | GetRef
   | SetRef
   | ModRef
   -- Noinline
   | NoInline
   -- Num
   | Abs
   | Sign
   | Add
   | Sub
   | Mul
   -- Par
   | ParRun
   | ParGet
   | ParFork
   | ParNew
   | ParYield
   | ParPut
   -- Ord
   | LTH
   | GTH
   | LTE
   | GTE
   | Min
   | Max
   -- RealFloat
   | Atan2
   -- Save
   | Save
   -- SizeProp
   | PropSize
   -- SourceInfo
   | SourceInfo String
   -- Switch
   | Switch
   -- Tuples
   | Tup
   | Sel Int -- These are zero indexed.
   | Drop Int
   -- Common nodes
   | Call Fork String
   deriving (Eq, Show)

-- | The main type: Variables, Bindings, Literals and Applications.
data UntypedFeldF e =
   -- Binding
     Variable Var
   | Lambda Var e
   | LetFun (String, Fork, e) e -- Note [Function bindings]
   -- Literal
   | Literal Lit
   -- Common nodes
   | App Op Type [e]
   deriving (Eq)

{-

Function bindings
-----------------

The LetFun constructor is different from the ordinary let-bindings,
and therefore has its own node type. In an ordinary language the
constructor would be called LetRec, but we do not have any
recursion. Functions are created by the createTasks pass, and they can
be run sequentially or concurrently depending on the "Fork".

-}

instance (Show e) => Show (UntypedFeldF e) where
   show (Variable v)                = show v
   show (Lambda v e)                = "(\\" ++ show v ++ " -> " ++ show e ++ ")"
   show (LetFun (s, k, e1) e2)      = "letFun " ++ show k ++ " " ++ s ++" = "++ show e1 ++ " in " ++ show e2
   show (Literal l) = show l
   show (App p@RunMutableArray _ [e]) = show p ++ " (" ++ show e ++ ")"
   show (App GetIx _ [e1,e2])       = "(" ++ show e1 ++ " ! " ++ show e2 ++ ")"
   show (App Add _ [e1,e2])         = "(" ++ show e1 ++ " + " ++ show e2 ++ ")"
   show (App Sub _ [e1,e2])         = "(" ++ show e1 ++ " - " ++ show e2 ++ ")"
   show (App Mul _ [e1,e2])         = "(" ++ show e1 ++ " * " ++ show e2 ++ ")"
   show (App Div _ [e1,e2])         = "(" ++ show e1 ++ " / " ++ show e2 ++ ")"
   show (App p@Then _ [e1, e2])     = show p ++ " (" ++ show e1 ++ ") (" ++
                                      show e2 ++ ")"
   show (App p _ [e1, e2])
    | p `elem` [Bind, Let, EPar]    = show p ++ " (" ++ show e1 ++ ") " ++ show e2
   show (App (ForeignImport s) _ es)= s ++ " " ++ unwords (map show es)
   show (App Tup _ es)              = "("   ++ intercalate ", " (map show es) ++ ")"
   show (App p@Parallel _ [e1,e2]) = show p ++ " (" ++ show e1 ++ ") " ++ show e2
   show (App p@Sequential _ [e1,e2,e3]) = show p ++ " (" ++ show e1 ++ ") (" ++ show e2 ++ ") " ++ show e3
   show (App p t es)
    | p `elem` [F2I, I2N, B2I, Round, Ceiling, Floor]
    = show p ++ "{" ++ show t ++ "} " ++ unwords (map show es)
   show (App p _ es)                = show p ++ " " ++ unwords (map show es)

-- | Compute a compact text representation of a scalar type
prTypeST :: ScalarType -> String
prTypeST BoolType         = "bool"
prTypeST BitType          = "bit"
prTypeST (IntType s sz)   = prS s ++ prSz sz
  where prS Signed   = "i"
        prS Unsigned = "u"
        prSz s       = drop 1 $ show s
prTypeST FloatType        = "f32"
prTypeST DoubleType       = "f64"
prTypeST (ComplexType t)  = "c" ++ prType t

-- | Compute a compact text representation of a type
prType :: Type -> String
prType (n :# t)         = show n ++ 'x':prTypeST t
prType (TupType ts)     = "(" ++ intercalate "," (map prType ts) ++ ")"
prType (MutType t)      = "M" ++ prType t
prType (RefType t)      = "R" ++ prType t
prType (ArrayType _ t)  = "a" ++ prType t
prType (MArrType _ t)   = "A" ++ prType t
prType (ParType t)      = "P" ++ prType t
prType (ElementsType t) = "e" ++ prType t
prType (IVarType t)     = "V" ++ prType t
prType (FunType t1 t2)  = "(" ++ prType t1 ++ "->" ++ prType t2 ++ ")"
prType (FValType t)     = "F" ++ prType t

-- | Convert an untyped unannotated syntax tree into a @Tree@ of @String@s
stringTree :: AUntypedFeld a -> Tree String
stringTree = stringTreeExp (const "")

-- | Convert an untyped annotated syntax tree into a @Tree@ of @String@s
stringTreeExp :: (a -> String) -> AUntypedFeld a -> Tree String
stringTreeExp prA = go
  where
    go (AIn r (Variable v))         = Node (show v ++ prC (typeof v) ++ prA r) []
    go (AIn _ (Lambda v e))         = Node ("Lambda "++show v ++ prC (typeof v)) [go e]
    go (AIn _ (LetFun (s,k,e1) e2)) = Node (unwords ["LetFun", show k, s]) [go e1, go e2]
    go (AIn _ (Literal l))          = Node (show l ++ prC (typeof l)) []
    go (AIn r (App Let t es))       = Node "Let" $ goLet $ AIn r (App Let t es)
    go (AIn r (App p t es))         = Node (show p ++ prP t r) (map go es)
    goLet (AIn _ (App Let _ [eRhs, AIn _ (Lambda v e)]))
                                    = Node ("Var " ++ show v ++ prC (typeof v) ++ " = ") [go eRhs]
                                    : goLet e
    goLet e = [Node "In" [go e]]
    prP t r = " {" ++ prType t ++ prA r ++ "}"
    prC t   = " : " ++ prType t

prettyExp :: (Type -> a -> String) -> AUntypedFeld a -> String
prettyExp prA e = render (pr 0 0 e)
  where pr p i (AIn r e) = pe p i r e
        pe _ i _ (Variable v) = line i $ show v
        pe _ i _ (Literal l) = line i $ show l
        pe p i _ (Lambda v e) = par p 0 $ join $ line i ("\\ " ++ pv Nothing v ++ " ->") ++ pr 0 (i+2) e
        pe p i r (App Let t es) = par p 0 $ line i "let" ++ pLet i (AIn r $ App Let t es)
        pe p i r (App f t es) = par p 10 $ join $ line i (show f ++ prP t r) ++ pArgs p (i+2) es
        pe _ i _ (LetFun (s,k,body) e) = line i ("letfun " ++ show k ++ " " ++ s)
                                         ++ pr 0 (i+2) body
                                         ++ line i "in"
                                         ++ pr 0 (i+2) e

        pArgs _ _ [] = []
        pArgs p i [e@(AIn _ (Lambda _ _))] = pr p i e
        pArgs p i (e:es) = pr 11 i e ++ pArgs p i es

        pLet i (AIn _ (App Let _ [eRhs, AIn _ (Lambda v e)]))
               = join (line (i+2) (pv Nothing v ++ " =") ++ pr 0 (i+4) eRhs) ++ pLet i e
        pLet i e = line i "in" ++ pr 0 (i+2) e

        pv mr v = show v ++ prC (typeof v) ++ maybe "" (prA $ typeof v) mr

        prP t r = " {" ++ prType t ++ prA t r ++ "}"
        prC t   = " : " ++ prType t

        par _ _ [] = error "UntypedRepresentation.prettyExp: parethesisizing empty text"
        par p i ls = if p <= i then ls else prepend "(" $ append ")" ls
        prepend s ((i,n,v) : ls) = (i, n + length s, s ++ v) : ls
        append s [(i,n,v)] = [(i, n + length s, v ++ s)]
        append s (l:ls) = l : append s ls

        join (x:y:xs)
          | indent x <= indent y &&
            all ((==) (indent y) . indent) xs &&
            l <= 60
          = [(indent x, l, unwords $ map val $ x:y:xs)]
            where l = sum (map len $ x:y:xs) + length xs + 1
        join xs = xs
        render = foldr (\ (i,_,cs) str -> replicate i ' ' ++ cs ++ "\n" ++ str) ""
        line i cs = [(i, length cs, cs)]
        indent (i,_,_) = i
        len (_,l,_) = l
        val (_,_,v) = v

        -- In the precedence argument, 0 means that no expressions need parentesis,
        -- wheras 10 accepts applications and 11 only accepts atoms (variables and literals)

class HasType a where
    type TypeOf a
    typeof :: a -> TypeOf a

instance HasType Var where
    type TypeOf Var = Type
    typeof Var{..}  = varType

instance HasType Lit where
    type TypeOf Lit       = Type
    typeof (LInt s n _)   = 1 :# IntType s n
    typeof LDouble{}      = 1 :# DoubleType
    typeof LFloat{}       = 1 :# FloatType
    typeof LBool{}        = 1 :# BoolType
    typeof LString{}      = StringType
    typeof (LArray t es) = ArrayType (singletonRange $ fromIntegral $ length es) t
    typeof (LComplex r _) = 1 :# ComplexType (typeof r)
    typeof (LTup ls)      = TupType $ map typeof ls

instance HasType (AUntypedFeld a) where
    type TypeOf (AUntypedFeld a)           = Type
   -- Binding
    typeof (AIn _ (Variable v))            = typeof v
    typeof (AIn _ (Lambda v e))            = FunType (typeof v) (typeof e)
    typeof (AIn _ (LetFun _ e))            = typeof e
   -- Literal
    typeof (AIn _ (Literal l))             = typeof l
    typeof (AIn _ (App _ t _))             = t

-- | Get free variables and their annotations for an AUntypedFeld expression
fv :: AUntypedFeld a -> [(a, Var)]
fv = nubBy ((==) `on` snd) . fvA' []

-- | Internal helper function for fv
fvA' :: [Var] -> AUntypedFeld a -> [(a, Var)]
   -- Binding
fvA' vs (AIn r (Variable v)) | v `elem` vs = []
                             | otherwise   = [(r, v)]
fvA' vs (AIn _ (Lambda v e))               = fvA' (v:vs) e
fvA' vs (AIn _ (LetFun (_, _, e1) e2))     = fvA' vs e1 ++ fvA' vs e2
   -- Literal
fvA' _  (AIn _ Literal{})                  = []
-- Common nodes.
fvA' vs (AIn _ (App _ _ es))               = concatMap (fvA' vs) es

-- | Collect nested let binders into the binders and the body.
collectLetBinders :: AUntypedFeld a -> ([(Var, AUntypedFeld a)], AUntypedFeld a)
collectLetBinders = go []
  where go acc (AIn _ (App Let _ [e, AIn _ (Lambda v b)])) = go ((v, e):acc) b
        go acc e                                           = (reverse acc, e)

-- | Collect binders from nested lambda expressions.
collectBinders :: AUntypedFeld a -> ([(a, Var)], AUntypedFeld a)
collectBinders = go []
  where go acc (AIn a (Lambda v e)) = go ((a,v):acc) e
        go acc e                    = (reverse acc, e)

-- | Inverse of collectLetBinders, put the term back together.
mkLets :: ([(Var, AUntypedFeld a)], AUntypedFeld a) -> AUntypedFeld a
mkLets ([], body)       = body
mkLets ((v, e):t, body) = AIn r (App Let t' [e, body'])
  where body'        = AIn r (Lambda v (mkLets (t, body))) -- Value info of result
        FunType _ t' = typeof body'
        r            = getAnnotation body

-- | Inverse of collectBinders, make a lambda abstraction.
mkLam :: [(a, Var)] -> AUntypedFeld a -> AUntypedFeld a
mkLam []         e = e
mkLam ((a, h):t) e = AIn a (Lambda h (mkLam t e))

-- | Make an application.
mkApp :: a -> Type -> Op -> [AUntypedFeld a] -> AUntypedFeld a
mkApp a t p es = AIn a (App p t es)

-- | Make a tuple; constructs the type from the types of the components
mkTup :: a -> [AUntypedFeld a] -> AUntypedFeld a
mkTup a es = AIn a $ App Tup (TupType $ map typeof es) es

-- | Substitute new for dst in e. Assumes no shadowing.
subst :: AUntypedFeld a -> Var -> AUntypedFeld a -> AUntypedFeld a
subst new dst = go
  where go v@(AIn _ (Variable v')) | dst == v' = new -- Replace.
                                   | otherwise = v -- Stop.
        go l@(AIn r (Lambda v e')) | v == dst  = l -- Stop.
                                   | otherwise = AIn r (Lambda v (go e'))
        go (AIn r (LetFun (s, k, e1) e2))
           = AIn r (LetFun (s, k, go e1) (go e2)) -- Recurse.
        go l@(AIn _ Literal{})  = l -- Stop.
        go (AIn r (App p t es)) = AIn r (App p t (map go es)) -- Recurse.

-- | Expressions that can and should be shared
sharable :: AUntypedFeld a -> Bool
sharable e = legalToShare e && goodToShare e

-- | Expressions that can be shared without breaking fromCore
legalToShare :: AUntypedFeld a -> Bool
legalToShare (AIn _ (App op _ _)) = op `notElem` [ESkip, EWrite, EPar, EparFor,
                                                  Return, Bind, Then, When,
                                                  NewArr, NewArr_, GetArr, SetArr, ArrLength,
                                                  For, While,
                                                  NewRef, GetRef, SetRef, ModRef]
legalToShare (AIn _ (Lambda _ _)) = False
legalToShare _                    = True

-- | Expressions that are expensive enough to be worth sharing
goodToShare :: AUntypedFeld a -> Bool
goodToShare (AIn _ (Literal l))
  | LArray _ (_:_) <- l = True
  | LTup (_:_)     <- l = True
goodToShare (AIn _ App{})       = True
goodToShare _                   = False

legalToInline :: AUntypedFeld a -> Bool
legalToInline _                    = True

type Rename a = State VarId a

rename :: AUntypedFeld a -> Rename (AUntypedFeld a)
rename = renameA M.empty

type RRExp a = UntypedFeldF (AUntypedFeld a)

renameA :: M.Map VarId (RRExp a) -> AUntypedFeld a -> Rename (AUntypedFeld a)
renameA env (AIn a r) = do r1 <- renameR env r
                           return $ AIn a r1

renameR :: M.Map VarId (RRExp a) -> RRExp a -> Rename (RRExp a)
renameR env (Variable v) = return $ env M.! varNum v
renameR env (App f t es) = do es1 <- mapM (renameA env) es
                              return $ App f t es1
renameR env (Lambda v e) = do v1 <- newVar v
                              e1 <- renameA (M.insert (varNum v) (Variable v1) env) e
                              return $ Lambda v1 e1
renameR _   (Literal l) = return $ Literal l
renameR _   e = error $ "FromTyped.renameR: unexpected expression " ++ show e

newVar :: MonadState VarId m => Var -> m Var
newVar v = do j <- get
              put (j+1)
              return $ v{varNum = j}
