{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances#-}
{-# LANGUAGE Strict #-}
module Physics (
  PhysSim(..),
  Mover(..),
  PhysObj(..),
  acceleration,
  velocity,
  Physics.position,
  torque,
  aVelocity ,
  orientation ,
  mover ,
  shape ,
  collisionFilter ,
  inertia  ,
  aInertia  ,
  elasticity ,
  friction,
  newPhysObj,
  newMover
) where

import Linear (V2(..),_xy,(^*),dot,crossZ,V3(..),cross,(^/),normalize)
import Prelude hiding ((.),id)
import Geometry as G hiding (orientation)
import Data.List
import qualified Data.Map.Strict as Map
import Control.Lens hiding (Empty)
import Control.Monad.Writer.Lazy (tell)
import Control.Applicative
import Data.Dynamic
import Data.Maybe (mapMaybe,fromJust,isNothing,isJust)
import Debug.Trace
import Data.Function hiding ((.),id)
import Wires
import Entity
import Data.Typeable
import Renderer (Shaped,shape)

data Mover = Mover {
  _acceleration :: V2 Float,
  _velocity ::  V2 Float,
  _position :: V2 Float,
  _torque :: Float,
  _aVelocity :: Float,
  _orientation ::  Float,
  _mident:: (TypeRep,Int)
} deriving Show
makeLenses ''Mover

instance HasId Mover where
  ident = mident

data Collision = Collision (TypeRep,Int) (TypeRep,Int) Manifold deriving Show

doMove:: Float -> Mover -> Mover--second order euler
doMove delta (Mover a v p t avel o i) =
     Mover  a
            (v + a^*delta)
            (p + v^*delta + a^*(delta^2)/2)
            t
            (avel + t*delta)
            (o + delta*avel + (delta^2)*t/2)
            i

newMover :: (TypeRep,Int) -> Mover
newMover = let z = (V2 0 0) in Mover z z z 0 0 0

data PhysObj = PhysObj {
  _mover :: Mover,
  _pshape :: PhysShape,
  _collisionFilter:: (TypeRep,Int)->Bool,
  _impulseFilter::(TypeRep,Int)->Bool,
  _inertia :: Float,
  _aInertia :: Float,
  _elasticity :: Float,
  _friction :: V2 Float
}
makeLenses ''PhysObj
instance Shaped PhysObj where
  shape = pshape

_shape = _pshape

instance HasId PhysObj where
  ident = mover.mident

instance Show PhysObj where
  show (PhysObj m s _ _ i a e f) =
    "(PhysObj" ++ show m ++ " " ++ show s ++ " " ++ show i ++ " " ++ show a ++ " " ++ show e ++ " " ++ show f ++ ")"

newPhysObj:: (TypeRep,Int) -> PhysShape -> PhysObj
newPhysObj i s = PhysObj (newMover i){_position = s^.G.position} s (const True) (const True) 1 1 0.5 (V2 0.8 0.5)

doMoveP:: Float -> PhysObj -> PhysObj--second order euler
doMoveP delta p =
     let m'= doMove delta (p ^. mover)
     in p{_mover=m', _pshape=((p ^. shape) & G.position .~ (m' ^. Physics.position)) & orient .~ (m' ^. orientation) }

data QuadTree =
  Tree {
    nw::QuadTree,
    ne::QuadTree,
    sw::QuadTree,
    se::QuadTree,
    members::[(PhysObj,PhysShape)],
    size :: Int,
    box::PhysShape
  }
  | Empty deriving Show

within :: PhysShape -> PhysShape -> Bool
within (Box (V2 x1 y1) (V2 w1 h1)) (Box (V2 x2 y2) (V2 w2 h2)) =
  x2<x1 && x2+w2>x1+w1 && y2<y1 && y2+h2>y1+h1

newQTree = Tree Empty Empty Empty Empty [] 0
addToQTree :: QuadTree -> (PhysObj,PhysShape) -> QuadTree
addToQTree t@(Tree Empty Empty Empty Empty mems s b@(Box (V2 x y) d )) m
  | s == 3 =
    let dm@(V2 w h) = d/2
    in Tree (newQTree $ Box (V2 x (y+h)) dm)
            (newQTree $ Box (V2 (x+w) (y+h)) dm)
            (newQTree $ Box (V2 x y) dm)
            (newQTree $ Box (V2 (x+w) y) dm)
            (m:mems)
            (s+1)
            b
  | otherwise = t{members = m:mems}
addToQTree t@(Tree nw@Tree{box=nwb} ne@Tree{box=neb} sw@Tree{box=swb} se@Tree{box=seb} mem s _) m@(_,b)
  | b `within` nwb = t{nw = addToQTree nw m}
  | b `within` neb = t{ne = addToQTree ne m}
  | b `within` swb = t{sw = addToQTree sw m}
  | b `within` seb = t{se = addToQTree se m}
  | otherwise      = t{members = m:mem,size = s+1}


buildTree :: [(PhysObj,PhysShape)] -> QuadTree
buildTree ojs =
  let (minx,miny, maxx,maxy) =
        foldl' (\(minx,miny,maxx,maxy) (_,Box (V2 x y) (V2 w h)) ->
                  (min minx x, min miny y,max maxx (x+w), max maxy (y+h)))
                    (1/0,1/0,negate 1/0, negate 1/0) ojs
  in foldl' addToQTree (newQTree $ Box (V2 minx miny ) (V2 (maxx-minx) (maxy-miny))) ojs

toEvents :: QuadTree -> [Collision]
toEvents Empty = []
toEvents t@Tree{members=mems} =
  let getEvents :: QuadTree -> (PhysObj,PhysShape) -> [Collision] ->  [Collision]
      getEvents Empty _ l = l
      getEvents (Tree nw ne sw se mems s qb) c@(o,sb) l
        | bound sb qb =
          let tp = filter (\ (po,bo) -> _collisionFilter o (po ^?! mover . ident) && bound bo sb ) mems
              pairsToEvents = mapMaybe (\(po,_) -> collision (_shape o) (_shape po) >>=
                        (\m -> Just $ Collision(_mident $ _mover o) (_mident $ _mover po) m))
          in  getEvents sw c $ getEvents se c $ getEvents ne c $ getEvents nw c ((pairsToEvents {-$ traceShowId-} tp) ++ l)
        | otherwise   =  l
      tailRecur Empty l = l
      tailRecur t@Tree{members=(x:xs)} l = tailRecur t{members=xs} $ getEvents t{members=xs} x l
      tailRecur (Tree ne nw se sw [] _ _) l =
        tailRecur ne $ tailRecur nw $ tailRecur se $ tailRecur sw l
  in tailRecur t []

doImpulse :: PhysObj-> PhysObj -> Manifold -> Float -> (PhysObj,PhysObj)
doImpulse a@PhysObj{_mover=(Mover aa va pa ta ava oa _)}
          b@PhysObj{_mover=(Mover ab vb pb tb avb ob _)}
          (Manifold p n t d)
          delta
          =
  let distsqrd (V2 x y) = x^2 + y^2
      norm = normalize n
      testSign = signum d
      getVel vel opos avel = vel + ((V3 0 0 (avel) `cross` (pure 0 & _xy .~ (p-opos))) ^. _xy)
      apvel = getVel va pa ava
      bpvel = getVel vb pb avb
      rvel = bpvel-apvel
      ra =  p - pa
      rb =  p - pb
      ifa = ((ra `crossZ` n)^2) / _aInertia a
      ifb = ((rb `crossZ` n)^2) / _aInertia b
      ti = ifa + ifb + (1/_inertia a) + (1/_inertia b)
      e = 1 + (_elasticity a + _elasticity b )/2
      imag = (e * dot norm rvel)/ti
      (V2 staticf dynamicf) = (_friction a  + _friction a )/2
      impulse = (norm ^* imag)
      applyImpulse :: PhysObj -> V2 Float -> V2 Float -> PhysObj
      applyImpulse o@PhysObj{_mover=m} imp r =
        o{ _mover = m { _velocity =_velocity m + (imp ^/ _inertia o),
                           _aVelocity = _aVelocity m + ((r `crossZ` imp) / _aInertia o)
                          }}
      nimp = norm ^* (rvel `dot` norm)
      tang = normalize $ rvel - nimp
      fric = (tang `dot` rvel)/ti
      fricMag = ( if abs fric < abs (imag*staticf) then fric else -imag*dynamicf )
      fricv = tang ^* fricMag
      ms = a^.inertia + b^.inertia
      doImpulse o r s =
          let o' = if  (rvel `dot` n) <  -0.00001 then
                      applyImpulse o (impulse^*s) r
                      else o
              o'' = if (tang `dot` rvel) > 0.00001 then
                      applyImpulse o' (fricv^*s) r
                      else o'
          in o''
  in  if _inertia a == (1/0) && _inertia b == (1/0) || (rvel `dot` n) >=  -0.00001 then
        (a,b)
      else
        ((((doImpulse $! a) $! ra) $! 1),((((doImpulse $! b) $! rb) $! (-1))))

data PhysSim = Sim {
  movers:: Map.Map (TypeRep,Int) Mover,
  physObjs:: Map.Map (TypeRep,Int) PhysObj,
  collisions :: Map.Map (TypeRep,Int) Collision
} deriving Show

instance HasId PhysSim

instance EntityW '[] '[Mover,PhysObj] PhysSim '[] where
  wire = mkPure $ \ds (_,newMovers `SCons`newObjects `SCons` SNil)  ->
    let dt = realToFrac $ dtime ds
        n = 10
        m' =  Map.map (doMove dt) (foldl' (\m x -> Map.insert (x^?!ident) x m ) Map.empty (map _payload newMovers) )
        o' =  Map.map (doMoveP dt) (foldl' (\o x -> Map.insert (x^?!mover.ident) x o ) Map.empty (map _payload newObjects) )
        events = toEvents $ buildTree $ map (\p->(p,toBound $ _shape p)) $ Map.elems o'
        {-events =  fix (\f list out-> if null list then out else let h = head list in
                      f (tail list) $
                        foldl' (\outl (a,b,m)-> if isJust m then CollisionEvent (a^.mover.ident) (b^.mover.ident) (fromJust m) : outl else outl) out $
                          foldl' (\clist x-> if bound (x^.shape) (h^.shape) then (x,h, collision (x^.shape) (h^.shape) ): clist else clist) [] (tail list) ) (Map.elems o') []-}
        (o''',_) = fix (\f (o'',n')->
                          if n'>0 then
                            f $! (foldl' (\mp (Collision a b m) ->
                            let pa = o'' Map.! a
                                pb = o'' Map.! b
                            in
                              if _impulseFilter pa b && _impulseFilter pb a then
                                  let look o = fromJust . Map.lookup ( _mident $ _mover o)
                                      (pa', pb') = doImpulse (look pa mp) (look pb mp) m (1/n)
                                  in (Map.insert b pb' (Map.insert a pa' mp))
                                else mp
                            ) o'' events , n'-1)
                          else (foldl' (\mp (Collision a b m) ->
                          let pa = o'' Map.! a
                              pb = o'' Map.! b
                          in
                            if _impulseFilter pa b && _impulseFilter pb a then
                                let look o = fromJust . Map.lookup ( _mident $ _mover o)
                                    translateP p v =
                                      (p & (mover . Physics.position) %~ (+v)) & (shape . G.position) %~ (+v)
                                    (pao,pbo) = (look pa mp,look pb mp)
                                    ms = _inertia pao + _inertia pbo
                                    doTranslate o s =
                                      translateP o
                                                (transVec m ^* ( s* offset m * (if ms == 1/0 then (if _inertia o == (1/0) then 0 else 1) else  _inertia o/ms )))
                                in (Map.insert b (doTranslate (look pb mp) (-1)) (Map.insert a (doTranslate (look pa mp) 1) mp))
                              else mp
                          ) o'' events,0)) (o',n)
        lst =  Map.elems o'''
    in  (Wires.Right ([Sim m' o''' (Map.fromList $ concatMap (\c@(Collision a b m) -> [(a,c),(b,c)]) events)],SNil),wire)


instance EntityW '[PhysSim] '[] (Map.Map EntityId Mover) '[] where
  wire = first . arr $ pure.movers.head.headE

instance EntityW '[PhysSim] '[] (Map.Map EntityId PhysObj) '[] where
  wire = first . arr $ pure.physObjs.head.headE

instance EntityW '[PhysSim] '[] (Map.Map EntityId Collision) '[] where
  wire = first . arr $ pure.collisions.head.headE

{-instance Entity PhysSim where
  getId = const physId
  doUpdate (Create d) _ s@(Sim m o) =
    let a d' =  (\l->(Sim m (foldl' (\o' p -> Map.insert (getSId p) p o') o l), False)) <$> (fromDynamic d' :: Maybe [PhysObj])
        b d' =  (\l->(Sim (foldl' (\m' p -> Map.insert (getSId p) p m') m l) o, False)) <$> (fromDynamic d' :: Maybe [Mover])
    in  return $ fromJust $ a d <|> b d <|> Just (s,True)
  doUpdate (Update delta) _ (Sim m o)= do
    let n = 20
        m' = Map.map (doMove delta) m
        o' = Map.map (doMoveP delta) o
        --events = toEvents $ buildTree $ map (\p->(p,toBound $ _shape p)) $ Map.elems o'
        events = fix (\f list out-> if null list then out else let h = head list in
                      f (tail list) $
                        foldl' (\outl (a,b,m)-> if isJust m then CollisionEvent (a^.mover.ident) (b^.mover.ident) (fromJust m) : outl else outl) out $
                          foldl' (\clist x-> if bound (x^.shape) (h^.shape) then (x,h,collision (x^.shape) (h^.shape)): clist else clist) [] (tail list) ) (Map.elems o') []
        (o''',_) = fix (\f (o'',n')->
                          if n'>0 then
                            f $! (foldl' (\mp (CollisionEvent a b m) ->
                            let pa = o'' Map.! a
                                pb = o'' Map.! b
                            in
                              if _impulseFilter pa b && _impulseFilter pb a then
                                  let look o = fromJust . Map.lookup ( _ident $ _mover o)
                                      (pa', pb') = doImpulse (look pa mp) (look pb mp) m (1/n)
                                  in (Map.insert b pb' (Map.insert a pa' mp))
                                else mp
                            ) o'' events , n'-1)
                          else (o'',0)) (o',n)
  --  tell $ events
    return $ trace "update" (Sim m' o''',True)
  doUpdate _ _ s = return (s,True)

  doGetState i (Sim m o) =
    let mov = Map.lookup i m
        phy = Map.lookup i o
    in if isJust mov then Just $ toDyn $ fromJust mov else
          if isJust phy then Just $ toDyn $ fromJust phy else
             Nothing
-}