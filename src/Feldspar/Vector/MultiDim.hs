{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts      #-}
module Feldspar.Vector.MultiDim where

import qualified Prelude as P

import Language.Syntactic hiding (fold,size)
import Feldspar hiding (desugar,sugar,resugar)
import Feldspar.Vector.Shape


-- | * Slices

data All    = All
data Any sh = Any

data Slice ss where
  SZ    :: Slice Z
  (::.) :: Slice sl -> Data Length -> Slice (sl :. Data Length)
  (:::) :: Slice sl -> All -> Slice (sl :. All)
  SAny  :: Slice (Any sl)


type family FullShape ss
type instance FullShape Z                   = Z
type instance FullShape (Any sh)            = sh
type instance FullShape (sl :. Data Length) = FullShape sl :. Data Length
type instance FullShape (sl :. All)         = FullShape sl :. Data Length

type family SliceShape ss
type instance SliceShape Z                   = Z
type instance SliceShape (Any sh)            = sh
type instance SliceShape (sl :. Data Length) = SliceShape sl
type instance SliceShape (sl :. All)         = SliceShape sl :. Data Length

sliceOfFull :: Slice ss -> Shape (FullShape ss) -> Shape (SliceShape ss)
sliceOfFull SZ Z = Z
sliceOfFull SAny sh = sh
sliceOfFull (fsl ::. _) (ssl :. _) = sliceOfFull fsl ssl
sliceOfFull (fsl ::: All) (ssl :. s) = sliceOfFull fsl ssl :. s

fullOfSlice :: Slice ss -> Shape (SliceShape ss) -> Shape (FullShape ss)
fullOfSlice SZ Z = Z
fullOfSlice SAny sh = sh
fullOfSlice (fsl ::. n) ssl = fullOfSlice fsl ssl :. n
fullOfSlice (fsl ::: All) (ssl :. s) = fullOfSlice fsl ssl :. s

-- | * Vectors

data Pull sh a = Pull (Shape sh) (Shape sh -> a)

type DPull sh a = Pull sh (Data a)


instance (Syntax a, Shapely sh) => Syntactic (Pull sh a) where
    type Domain   (Pull sh a) = FeldDomain
    type Internal (Pull sh a) = ([Length],[Internal a])
    desugar = desugar . freezePull . map resugar
    sugar   = map resugar . thawPull . sugar

-- instance (Syntax a, Shapely sh) => Syntax (Pull sh a)

instance Functor (Pull sh)
  where
    fmap = map

-- | * Functions

-- | Store a vector in an array.
fromPull :: (Type a) => DPull sh a -> Data [a]
fromPull vec = parallel (size ext) (\ix -> vec !: fromIndex ext ix)
  where ext = extent vec

-- | Restore a vector from an array
toPull :: (Type a) => Shape sh -> Data [a] -> DPull sh a
toPull sh arr = Pull sh (\ix -> arr ! toIndex sh ix)

freezePull :: (Type a) => DPull sh a -> (Data [Length], Data [a])
freezePull v   = (shapeArr, fromPull v) -- TODO should be fromPull' to remove div and mod
  where shapeArr = fromList (toList $ extent v)

fromList :: Type a => [Data a] -> Data [a]
fromList ls = loop 1 (parallel (value len) (const (P.head ls)))
  where loop i arr
            | i P.< len = loop (i+1) (setIx arr (value i) (ls P.!! (P.fromIntegral i)))
            | otherwise = arr
        len  = P.fromIntegral $ P.length ls

thawPull :: (Type a, Shapely sh) => (Data [Length], Data [a]) -> DPull sh a
thawPull (l,arr) = toPull (toShape 0 l) arr

-- | Store a vector in memory. Use this function instead of 'force' if
--   possible as it is both much more safe and faster.
memorize :: (Type a) => DPull sh a -> DPull sh a
memorize vec = toPull (extent vec) (fromPull vec)

-- | A shape-aware version of parallel (though this implementation is
--   sequental).
parShape :: (Type a) => Shape sh -> (Shape sh -> Data a) -> Data [a]
parShape sh ixf = runMutableArray $ do
                   arr <- newArr_ (size sh)
                   forShape sh $ \i -> do
                     setArr arr (toIndex sh i) (ixf i)
                   return arr

-- | An alternative version of `fromVector` which uses `parShape`
fromVector' :: (Type a) => DPull sh a -> Data [a]
fromVector' (Pull sh ixf) = parShape sh ixf

-- | The shape and size of the vector
extent :: Pull sh a -> Shape sh
extent (Pull sh _) = sh

-- | Change the extent of the vector to the supplied value. If the supplied
-- extent will contain more elements than the old extent, the new elements 
-- will have undefined value.
newExtent :: Shape sh -> Pull sh a -> Pull sh a
newExtent sh (Pull _ ixf) = Pull sh ixf

indexed :: (Shape sh -> a) -> Shape sh -> Pull sh a
indexed ixf l = Pull l ixf

-- | Change shape and transform elements of a vector. This function is the
--   most general way of manipulating a vector.
traverse :: Pull sh  a -> (Shape sh -> Shape sh') ->
            ((Shape sh -> a) -> Shape sh' -> a') ->
            Pull sh' a'
traverse (Pull sh ixf) shf elemf
  = Pull (shf sh) (elemf ixf)

-- | Duplicates part of a vector along a new dimension.
replicate :: Slice ss -> Pull (SliceShape ss) a -> Pull (FullShape ss) a
replicate sl vec
 = backpermute (fullOfSlice sl (extent vec))
               (sliceOfFull sl) vec

-- | Extracts a slice from a vector.
slice :: Pull (FullShape ss) a -> Slice ss -> Pull (SliceShape ss) a
slice vec sl
 = backpermute (sliceOfFull sl (extent vec))
               (fullOfSlice sl) vec

-- | Change the shape of a vector. This function is potentially unsafe, the
--   new shape need to have fewer or equal number of elements compared to
--   the old shape.
reshape :: Shape sh -> Pull sh' a -> Pull sh a
reshape sh' (Pull sh ixf)
 = Pull sh' (ixf . fromIndex sh . toIndex sh')

-- | A scalar (zero dimensional) vector
unit :: a -> Pull Z a
unit a = Pull Z (const a)

-- | Index into a vector
(!:) :: Pull sh a -> Shape sh -> a
(Pull _ ixf) !: ix = ixf ix

-- | Extract the diagonal of a two dimensional vector
diagonal :: Pull DIM2 a -> Pull DIM1 a
diagonal vec = backpermute (Z :. width) (\ (_ :. x) -> Z :. x :. x) vec
  where (width : height : _) = toList (extent vec) -- brain explosion hack

-- | Change the shape of a vector.
backpermute :: Shape sh' -> (Shape sh' -> Shape sh) ->
               Pull sh a -> Pull sh' a
backpermute sh perm vec = traverse vec (const sh) (. perm)

permute :: (Shape sh -> Shape sh -> Shape sh) ->
           Pull sh a -> Pull sh a
permute perm (Pull sh ixf) = Pull sh (ixf . (perm sh))

-- | Map a function on all the elements of a vector
map :: (a -> b) -> Pull sh a -> Pull sh b
map f (Pull sh ixf) = Pull sh (f . ixf)

-- | Combines the elements of two vectors. The size of the resulting vector
--   will be the intersection of the two argument vectors.
zip :: Pull sh a -> Pull sh b -> Pull sh (a,b)
zip = zipWith (\a b -> (a,b))

-- | Combines the elements of two vectors pointwise using a function.
--   The size of the resulting vector will be the intersection of the
--   two argument vectors.
zipWith :: (a -> b -> c) -> Pull sh a -> Pull sh b -> Pull sh c
zipWith f arr1 arr2 = Pull (intersectDim (extent arr1) (extent arr2))
                      (\ix -> f (arr1 !: ix) (arr2 !: ix))

-- | Reduce a vector along its last dimension

fold :: (Syntax a) =>
        (a -> a -> a)
     -> a
     -> Pull (sh :. Data Length) a
     -> Pull sh a
fold f x vec = Pull sh ixf
    where (sh, n) = uncons (extent vec) -- brain explosion hack
          ixf i = forLoop n x (\ix s -> f s (vec !: (i :. ix)))

-- Here's another version of fold which has a little bit more freedom
-- when it comes to choosing the initial element when folding

-- | A generalization of 'fold' which allows for different initial
--   values when starting to fold.
fold' :: (Syntax a)
      => (a -> a -> a)
      -> Pull sh a
      -> Pull (sh :. Data Length) a
      -> Pull sh a
fold' f x vec = Pull sh ixf
    where (sh, n) = uncons (extent vec) -- brain explosion hack
          ixf i = forLoop n (x!:i) (\ix s -> f s (vec !: (i :. ix)))

-- | Summing a vector along its last dimension
sum :: (Syntax a, Num a) => Pull (sh :. Data Length) a -> Pull sh a
sum = fold (+) 0


-- | Concatenating shapes.
class ShapeConc sh1 sh2 where
  type ShapeConcT sh1 sh2
  shapeConc :: Shape sh1 -> Shape sh2 -> Shape (ShapeConcT sh1 sh2)

  splitIndex :: Shape (ShapeConcT sh1 sh2) -> Shape sh1 -> (Shape sh1,Shape sh2)

instance ShapeConc Z sh2 where
  type ShapeConcT Z sh2 = sh2
  shapeConc Z sh2 = sh2

  splitIndex sh Z = (Z,sh)

instance ShapeConc sh1 sh2 => ShapeConc (sh1 :. Data Length) sh2 where
  type ShapeConcT (sh1 :. Data Length) sh2 = ShapeConcT sh1 sh2 :. Data Length
  shapeConc (sh1 :. l) sh2 = shapeConc sh1 sh2 :. l

  splitIndex (sh :. i) (sh1 :. _) = (i1 :. i,i2)
    where (i1,i2) = splitIndex sh sh1

-- | Flatten nested vectors.
flatten :: forall a sh1 sh2.
           Shapely (ShapeConcT sh1 sh2) =>
          ShapeConc sh1 sh2 => Pull sh1 (Pull sh2 a)
       -> Pull (ShapeConcT sh1 sh2) a
flatten (Pull sh1 ixf1) = Pull sh ixf
  where ixf i = let (i1,i2) = splitIndex i sh1
  	       	    (Pull _ ixf2) = ixf1 i1
  	       	in ixf2 i2
        sh = let (i1,_ :: Shape sh2) = splitIndex fakeShape sh1
	         (Pull sh2 _) = ixf1 i1
	     in shapeConc sh1 sh2

-- Laplace

stencil :: DPull DIM2 Float -> DPull DIM2 Float
stencil vec
  = traverse vec id update
  where
    (width : height : _) = toList (extent vec) -- brain explosion hack

    update get d@(sh :. i :. j)
      = isBoundary i j ?
        get d
        $ (get (sh :. (i-1) :. j)
         + get (sh :. i     :. (j-1))
         + get (sh :. (i+1) :. j)
         + get (sh :. i     :. (j+1))) / 4

    isBoundary i j
      =  (i == 0) || (i >= width  - 1)
      || (j == 0) || (j >= height - 1)

laplace :: Data Length -> DPull DIM2 Float -> DPull DIM2 Float
laplace steps vec = toPull (extent vec) $
                    forLoop steps (fromPull vec) (\ix ->
                       fromPull . stencil . toPull (extent vec)
                    )


-- Matrix Multiplication

transpose :: forall sh e. Pull (sh :. Data Length :. Data Length) e
                       -> Pull (sh :. Data Length :. Data Length) e
transpose vec
  = backpermute new_extent swap vec
  where swap ((tail :: Shape sh) :. i :. j) = tail :. j :. i
        new_extent         = swap (extent vec)

transpose2D :: Pull DIM2 e -> Pull DIM2 e
transpose2D = transpose

-- | Matrix multiplication
mmMult :: (Syntax e, Num e) =>
          Pull DIM2 e -> Pull DIM2 e -> Pull DIM2 e
mmMult vA vB
  = sum (zipWith (*) vaRepl vbRepl)
  where
    tmp = transpose2D vB
    vaRepl = replicate (SZ ::: All   ::. colsB ::: All) vA
    vbRepl = replicate (SZ ::. rowsA ::: All   ::: All)  vB
    [rowsA, colsA] = toList (extent vA) -- brain explosion hack
    [rowsB, colsB] = toList (extent vB)


-- KFFs combinators

expandL :: Data Length -> Pull (sh :. Data Length) a -> Pull (sh :. Data Length :. Data Length) a
expandL n (Pull ext ixf) = Pull (insLeft n $ insLeft p $ ext') ixf'
  where (m, ext') = peelLeft ext
        p = m `div` n
        ixf' ix = let (i,ix') = peelLeft ix; (j,ix'') = peelLeft ix' in ixf $ insLeft (i*p + j) ix''

contractL :: Pull (sh :. Data Length :. Data Length) a -> Pull (sh :. Data Length) a
contractL (Pull ext ixf) = Pull (insLeft (m*n) ext') ixf'
  where (m, n, ext') = peelLeft2 ext
        ixf' ix = let (i,ix') = peelLeft ix in ixf $ insLeft (i `div` n) $ insLeft (i `mod` n) $ ix'

transL :: Pull (sh :. Data Length :. Data Length) a -> Pull (sh :. Data Length :. Data Length) a
transL (Pull ext ixf) = Pull (insLeft n $ insLeft m $ ext') ixf'
  where (m, n, ext') = peelLeft2 ext
        ixf' ix = let (i, j, ix') = peelLeft2 ix in ixf $ insLeft j $ insLeft i $ ix'


-- Note: curry is unsafe in that it produces an index function that does not check that its leftmost argument is in range
curryL :: Pull (sh :. Data Length) a -> (Data Length, Data Length -> Pull sh a)
curryL (Pull sh ixf) = (n, \ i -> Pull sh' (\ ix -> ixf $ insLeft i ix))
  where (n, sh') = peelLeft sh

uncurryL :: Data Length -> (Data Length -> Pull sh a) -> Pull (sh :. Data Length) a
uncurryL m f = Pull (insLeft m ext) ixf
  where Pull ext _ = f (undefined :: Data Length)
        ixf ix = let (i, ix') = peelLeft ix; Pull _ ixf' = f i in ixf' ix'

dmapL :: (Pull sh1 a1 -> Pull sh2 a2) -> Pull (sh1 :. Data Length) a1 -> Pull (sh2 :. Data Length) a2
dmapL f a = uncurryL n $ f . g
  where (n,g) = curryL a

dzipWithL :: (Pull sh1 a1 -> Pull sh2 a2 -> Pull sh3 a3) -> Pull (sh1 :. Data Length) a1 -> Pull (sh2 :. Data Length) a2
          -> Pull (sh3 :. Data Length) a3
dzipWithL f a1 a2 = uncurryL (min m n) $ \ i -> f (g i) (h i)
  where (m,g) = curryL a1
        (n,h) = curryL a2

-- Convenience functions that maybe should not be in the lib

expandLT :: Data Length -> Pull (sh :. Data Length) a -> Pull (sh :. Data Length :. Data Length) a
expandLT n a = transL $ expandL n $ a

contractLT :: Pull (sh :. Data Length :. Data Length) a -> Pull (sh :. Data Length) a
contractLT a = contractL $ transL $ a



{-

Here is some functions that use both pull and push vectors (pull in, push out). Hence they do not build in the current module structure,
so I include them in the form of comments. Should be uncommentable in a joint module, modulo renaming ;-)

Only difference to the pure pull variants is the use of uncurryS instead of uncurryL.

By the way: S.Vector is push vector

dmapS :: (Pull sh1 a1 -> S.Vector sh2 a2) -> Pull (sh1 :. Data Length) a1 -> S.Vector (sh2 :. Data Length) a2
dmapS f a = uncurryS n $ f . g
  where (n,g) = curryL a

dzipWithS :: (Pull sh1 a1 -> L.Vector sh2 a2 -> S.Vector sh3 a3) -> L.Vector (sh1 :. Data Length) a1 -> Pull (sh2 :. Data Length) a2
          -> S.Vector (sh3 :. Data Length) a3
dzipWithS f a1 a2 = uncurryS (min m n) $ \ i -> f (g i) (h i)
  where (m,g) = curryL a1
        (n,h) = curryL a2

-}


