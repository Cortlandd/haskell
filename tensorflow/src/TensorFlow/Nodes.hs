-- Copyright 2016 TensorFlow authors.
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
module TensorFlow.Nodes where

import Control.Applicative (liftA2, liftA3)
import Data.Map.Strict (Map)
import Data.Monoid ((<>))
import Data.Set (Set)
import Data.String (IsString)
import Data.Text (Text)
import Lens.Family2 ((^.))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import qualified Data.Vector as V

import TensorFlow.Build
import TensorFlow.Output
import TensorFlow.Tensor
import TensorFlow.Types
import qualified TensorFlow.Internal.FFI as FFI

-- | Types that contain ops which can be run.
class Nodes t where
    getNodes :: t -> Build (Set NodeName)

-- | Types that tensor representations (e.g. 'Tensor', 'ControlNode') can be
-- fetched into.
--
-- Includes collections of tensors (e.g. tuples).
class Nodes t => Fetchable t a where
    getFetch :: t -> Build (Fetch a)

-- | Fetch action. Keeps track of what needs to be fetched and how to decode
-- the fetched data.
data Fetch a = Fetch
          { -- | Nodes to fetch
            fetches :: Set Text
            -- | Function to create an 'a' from the fetched data.
          , fetchRestore :: Map Text FFI.TensorData -> a
          }

instance Functor Fetch where
    fmap f (Fetch fetch restore) = Fetch fetch (f . restore)

instance Applicative Fetch where
    pure x = Fetch Set.empty (const x)
    Fetch fetch restore <*> Fetch fetch' restore' =
        Fetch (fetch <> fetch') (restore <*> restore')

nodesUnion :: (Monoid b, Traversable t, Applicative f) => t (f b) -> f b
nodesUnion = fmap (foldMap id) . sequenceA

instance (Nodes t1, Nodes t2) => Nodes (t1, t2) where
    getNodes (x, y) = nodesUnion [getNodes x, getNodes y]

instance (Nodes t1, Nodes t2, Nodes t3) => Nodes (t1, t2, t3) where
    getNodes (x, y, z) = nodesUnion [getNodes x, getNodes y, getNodes z]

instance (Fetchable t1 a1, Fetchable t2 a2) => Fetchable (t1, t2) (a1, a2) where
    getFetch (x, y) = liftA2 (,) <$> getFetch x <*> getFetch y

instance (Fetchable t1 a1, Fetchable t2 a2, Fetchable t3 a3)
         => Fetchable (t1, t2, t3) (a1, a2, a3) where
    getFetch (x, y, z) =
        liftA3 (,,) <$> getFetch x <*> getFetch y <*> getFetch z

instance Nodes t => Nodes [t] where
    getNodes = nodesUnion . map getNodes

instance Fetchable t a => Fetchable [t] [a] where
    getFetch ts  = sequenceA <$> mapM getFetch ts

instance Nodes ControlNode where
    getNodes (ControlNode o) = Set.singleton <$> getOrAddOp o

-- We use the constraint @(a ~ ())@ to help with type inference.  For example,
-- if @t :: ControlNode@, then this constraint ensures that @run t :: Session
-- ()@.  If we used @instance Fetchable ControlNode ()@ instead, then that
-- expression would be ambiguous without explicitly specifying the return type.
instance a ~ () => Fetchable ControlNode a where
    getFetch _ = return $ pure ()

instance Nodes (Tensor v a) where
    getNodes t = Set.singleton <$> getOrAddOp (t ^. tensorOutput . outputOp)

fetchTensorList :: TensorType a => Tensor v a -> Build (Fetch (Shape, [a]))
fetchTensorList t = fmap (fmap V.toList) <$> fetchTensorVector t

fetchTensorVector :: forall a v . TensorType a
                  => Tensor v a -> Build (Fetch (Shape, V.Vector a))
fetchTensorVector (Tensor _ o) = do
    outputName <- renderOutput o
    return $ Fetch (Set.singleton outputName) $ \tensors ->
        let tensorData = tensors Map.! outputName
            shape = Shape $ FFI.tensorDataDimensions tensorData
            vec = decodeTensorData $ TensorData tensorData

            expectedType = tensorType (undefined :: a)
            actualType = FFI.tensorDataType tensorData
            badTypeError = error $ "Bad tensor type: expected "
                                   ++ show expectedType
                                   ++ ", got "
                                   ++ show actualType
        in if expectedType /= actualType
               then badTypeError
               else (shape, vec)

-- The constraint "a ~ a'" means that the input/output of fetch can constrain
-- the TensorType of each other.
instance (TensorType a, a ~ a') => Fetchable (Tensor v a) (V.Vector a') where
    getFetch t = fmap snd <$> fetchTensorVector t

newtype Scalar a = Scalar {unScalar :: a}
    deriving (Show, Eq, Ord, Num, Fractional, Floating, Real, RealFloat,
              RealFrac, IsString)

instance (TensorType a, a ~ a') => Fetchable (Tensor v a) (Scalar a') where
    getFetch t = fmap (Scalar . headFromSingleton . snd) <$> fetchTensorList t
      where
        headFromSingleton [x] = x
        headFromSingleton xs
            = error $ "Unable to extract singleton from tensor of length "
                          ++ show (length xs)
