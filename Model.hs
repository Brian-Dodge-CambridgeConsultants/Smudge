{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}

module Model (
    EnterExitState(..),
    HappeningFlag(..),
    Happening(..),
    QualifiedName,
    Qualifiable(..),
    mangleWith,
    disqualify,
    disqualifyTag,
    TaggedName(..),
    qName,
    passInitialState,
    passFullyQualify,
    passTagCategories,
    passWholeStateToGraph,
) where

import Grammars.Smudge (
  Annotated(..),
  StateMachine(..),
  StateMachineDeclarator(..),
  State(..),
  Event(..),
  QEvent,
  Function(..),
  SideEffect(..),
  StateFlag(..),
  WholeState
  )
import Parsers.Id (
  Name,
  Identifier,
  mangle,
  )

import Data.Graph.Inductive.Graph (mkGraph, Node)
import Data.Graph.Inductive.PatriciaTree (Gr)
import Data.Map (Map, fromList, (!))
import Data.List (intercalate)
import Data.Foldable (asum)
import Control.Applicative (Alternative)
import Control.Arrow (first)

data EnterExitState = EnterExitState {
        en :: [SideEffect TaggedName],
        st :: State TaggedName,
        ex :: [SideEffect TaggedName]
    } deriving (Show, Eq, Ord)

data HappeningFlag = NoTransition
    deriving (Show, Eq, Ord)

data Happening = Happening {
        event       :: Event TaggedName,
        sideEffects :: [SideEffect TaggedName],
        flags       :: [HappeningFlag]
    } deriving (Show, Eq, Ord)

newtype Qualified a = Qualified [a]
    deriving (Eq, Ord, Applicative, Alternative, Functor, Monad)

instance Show a => Show (Qualified a) where
    show (Qualified as) = intercalate "." $ map show as

instance Read a => Read (Qualified a) where
    readsPrec d = readParen False
                    (\r -> map (first Qualified) $ readA r)
        where readA r = do
                    (a, s) <- readsPrec d r
                    case s of
                        '.' : s -> map (first (a:)) $ readA s
                        otherwise -> [([a], s)]

type QualifiedName = Qualified Identifier

class Qualifiable n where
    qualify :: n -> QualifiedName

instance Qualifiable QualifiedName where
    qualify = id

instance Qualifiable Identifier where
    qualify n = Qualified [n]

instance Qualifiable Name where
    qualify = read . ('@':)

instance (Qualifiable s, Qualifiable n) => Qualifiable (s, n) where
    qualify (s, n) = asum $ (qualify s) : [qualify n]

mangleWith :: (Name -> Name -> Name) -> (Name -> Name) -> QualifiedName -> Name
mangleWith _  _ (Qualified []) = ""
mangleWith ff f (Qualified ns) = foldr1 ff $ fmap (mangle f) ns

disqualify :: QualifiedName -> Name
disqualify = mangleWith seq id

data TaggedName =
          TagMachine QualifiedName
        | TagState QualifiedName
        | TagEvent QualifiedName
        | TagFunction QualifiedName
        | TagBuiltin QualifiedName
    deriving (Show, Eq, Ord)

instance Qualifiable TaggedName where
    qualify (TagMachine n) = n
    qualify (TagState n) = n
    qualify (TagEvent n) = n
    qualify (TagFunction n) = n
    qualify (TagBuiltin n) = n

disqualifyTag :: TaggedName -> Name
disqualifyTag = disqualify . qualify

passInitialState :: [(StateMachine Identifier, [WholeState Identifier])] -> [(StateMachine Identifier, [WholeState Identifier])]
passInitialState sms = map (\(sm, wss) -> (sm, foldr init [] wss)) sms
    where init ws@(s, fs, en, es, ex) wss | elem Initial fs = (StateEntry, [], [], [(EventEnter, [], s)], []) : (s, filter (/= Initial) fs, en, es, ex) : wss
          init ws wss = ws : wss    

pickSm :: StateMachineDeclarator a -> StateMachineDeclarator a -> StateMachineDeclarator a
pickSm _ s@(StateMachineDeclarator _) = s
pickSm s@(StateMachineDeclarator _) _ = s
pickSm StateMachineSame _ = undefined

instance Qualifiable (StateMachineDeclarator Identifier) where
    qualify (StateMachineDeclarator n) = qualify n
    qualify StateMachineSame           = undefined

instance Qualifiable (Event Identifier) where
    qualify (Event e) = qualify e
    qualify _         = undefined

qQE :: StateMachineDeclarator Identifier -> QEvent Identifier -> QualifiedName
qQE sm (sm', ev) = qualify (pickSm sm sm', ev)

qName :: StateMachineDeclarator Identifier -> SideEffect Identifier -> QualifiedName
qName _  (s, FuncVoid)    = qualify s
qName _  (s, FuncTyped _) = qualify s
qName sm (_, FuncEvent e) = qQE sm e

passFullyQualify :: [(StateMachine Identifier, [WholeState Identifier])] -> [(StateMachine QualifiedName, [WholeState QualifiedName])]
passFullyQualify sms = map qual sms
    where qual (Annotated a sm, wss) = (Annotated a $ qual_sm sm, map qual_ws wss)
            where qual_sm = fmap qualify
                  qual_ws (st, fs, en, es, ex) = (qual_st st, fs, map qual_fn en, map qual_eh es, map qual_fn ex)
                  qual_eh (ev, ses, s) = (qual_ev ev, map qual_fn ses, qual_st s)
                  qual_st = fmap (qualify . ((,) sm))
                  qual_ev = fmap (qualify . ((,) sm))
                  qual_qe ev@(sm', _) = (qual_sm $ pickSm sm sm', Event $ qQE sm ev)
                  qual_fn fn@(_, FuncVoid)     = (qName sm fn, FuncVoid)
                  qual_fn fn@(_, FuncTyped qe) = (qName sm fn, FuncTyped $ qual_qe qe)
                  qual_fn fn@(_, FuncEvent qe) = (qName sm fn, FuncEvent $ qual_qe qe)

passTagCategories :: [(StateMachine QualifiedName, [WholeState QualifiedName])] -> [(StateMachine TaggedName, [WholeState TaggedName])]
passTagCategories sms = map tag sms
    where tag (Annotated a sm, wss) = (Annotated a $ fmap TagMachine sm, map tag_ws wss)
          tag_ws (st, fs, en, es, ex) = (fmap TagState st, fs, map tag_fn en, map tag_eh es, map tag_fn ex)
          tag_eh (ev, ses, s) = (fmap TagEvent ev, map tag_fn ses, fmap TagState s)
          tag_qe (sm', ev) = (fmap TagMachine sm', fmap TagEvent ev)
          tag_fn (n, FuncVoid)     = (TagFunction n, FuncVoid)
          tag_fn (n, FuncTyped qe) = (TagFunction n, FuncTyped $ tag_qe qe)
          tag_fn (n, FuncEvent qe) = (TagFunction n, FuncEvent $ tag_qe qe)

smToGraph :: (StateMachine TaggedName, [WholeState TaggedName]) ->
                 Gr EnterExitState Happening
smToGraph (sm, ss) = mkGraph eess es
    where
        ss' = zip [1..] ss
        getEeState (n, (st, _, en, _, ex)) = (n, EnterExitState {..})
        eess = map getEeState ss'
        sn :: Map (State TaggedName) Node
        sn = fromList $ map (\(n, ees) -> (st ees, n)) eess
        mkEdge :: Node -> (State TaggedName) -> Happening -> (Node, Node, Happening)
        mkEdge n s'' eses = (n, sn ! s'', eses)
        es = [ese | ese <- concat $ map (\(n, (s, _, _, es, _)) -> map (g n s) es) ss']
        g :: Node -> (State TaggedName) -> (Event TaggedName, [SideEffect TaggedName], State TaggedName) -> (Node, Node, Happening)
        g n s (e, ses, s') =
            let (e', s'') = case s' of
                    StateSame -> (Happening e ses [NoTransition], s)
                    otherwise -> (Happening e ses [], s')
            in mkEdge n s'' e'

passWholeStateToGraph :: [(StateMachine TaggedName, [WholeState TaggedName])] ->
                            [(StateMachine TaggedName, Gr EnterExitState Happening)]
passWholeStateToGraph sms = zip (map fst sms) (map smToGraph sms)
