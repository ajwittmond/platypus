{-#LANGUAGE FlexibleInstances#-}
{-#LANGUAGE Arrows#-}
{-#LANGUAGE GADTs#-}
{-#LANGUAGE NegativeLiterals#-}
{-#LANGUAGE TypeFamilies #-}
module TestEntity where

import Entity

import Prelude hiding (id,(.))
import Data.Typeable
import Linear.V2
import Linear.Metric (signorm)
import Linear.Vector ((^*))
import Geometry
import Data.Bool
import SDL.Input.Keyboard
import Signals
import SDL.Input.Mouse
import Wires
import Shape
import Input hiding (position)
import Renderer
import Debug.Trace
import Control.Lens
import BasicGeometry
import Data.Bool
import Physics hiding (velocity,position)

newtype ControllableSquare = CSquare (V2 Float)

velocity = 400 :: Float
accel = 800 :: Float

{-instance EntityW '[Keyboard] '[] ControllableSquare '[DrawableObject ] where
  wire =
    let key vel code = modes False (bool (pure (-vel)) 0) <<< second (edge id) <<< arr ((\x->(x,x)).($ code))
    in proc ([Keyboard pressed] `ECons` _,SNil) -> do
        pos <-integral 0 <<< maxVelocityV accel <<< arr (\v-> if v ==0 then 0 else signorm v ^* velocity) <<<
          key (V2 1 0) ScancodeD + key (V2 -1 0) ScancodeA +
          key (V2 0 -1) ScancodeS + key (V2 0 1) ScancodeW -< pressed
        shap <- arr (DO . newShape . (`newOBB` 50)) -< pos
        returnA -< ([CSquare pos],sigify [shap] `SCons` SNil)-}

data Clicker = Clicker

instance EntityW '[Mouse] '[] Clicker '[Create DynamicGeom] where
  wire =
    let createVals s p i =
          let setPhysProps p = p{_aInertia=300000,_inertia=100} & mover.acceleration .~ (V2 0 -1000)
          in  DynGeo i (setPhysProps $ newPhysObj i (s p 50)) 1
    in proc ([Input.Mouse f p] `ECons` ENil,_) -> do
        e1 <- alternate never (periodic 0.2) <<< (id &&& edge id) <<< arr ($ ButtonRight) -< f
        e2 <- alternate never (periodic 0.2) <<< (id &&& edge id) <<< arr ($ ButtonLeft) -< f
        let out1 = ((createVals newCircle p) <$ e1)
        let out2 = ((createVals newOBB p) <$ e2)
        returnA -< ([Clicker],sigify [CNoId out1,CNoId out2] `SCons` SNil)
