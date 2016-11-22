{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE FlexibleContexts #-}

module Backends.CStatic where

import Backends.Backend (Backend(..))
import Grammars.Smudge (
  Annotated(..),
  StateMachineDeclarator(..),
  State(..),
  Event(..),
  Function(..),
  SideEffect(..),
  )
import Grammars.C89
import Model (
  EnterExitState(..),
  HappeningFlag(..),
  Happening(..),
  QualifiedName,
  Qualifiable(qualify),
  TaggedName(..),
  mangleWith,
  disqualifyTag,
  qName,
  )
import Semantics.Operation (handlers, finalStates)
import Semantics.Solver (
  Ty(..), 
  Binding(..), 
  resultOf,
  SymbolTable, 
  insertExternalSymbol, 
  (!),
  )
import qualified Semantics.Solver as Solver(toList)
import Trashcan.FilePath (relPath)
import Unparsers.C89 (renderPretty)

import Control.Monad (liftM)
import Data.Graph.Inductive.Graph (labNodes, labEdges, lab, out, suc, insEdges, nodes, delNodes)
import Data.List (intercalate, nub, sort, (\\))
import Data.Map (empty, toList)
import qualified Data.Map (null, (!))
import Data.Text (replace)
import System.Console.GetOpt
import System.IO.Unsafe (unsafePerformIO)
import System.FilePath (
  FilePath,
  dropExtension,
  takeDirectory,
  normalise,
  takeFileName,
  (<.>)
  )

data CStaticOption = OutFile FilePath
                   | Header FilePath
                   | ExtFile FilePath
                   | NoDebug
    deriving (Show, Eq)

apply :: PostfixExpression -> [AssignmentExpression] -> PostfixExpression
apply f [] = APostfixExpression f LEFTPAREN Nothing RIGHTPAREN
apply f ps = APostfixExpression f LEFTPAREN (Just $ fromList ps) RIGHTPAREN

(+-+) :: Identifier -> Identifier -> Identifier
a +-+ b = a ++ "_" ++ b

qualifyMangle :: Qualifiable q => q -> Identifier
qualifyMangle q = mangleWith (+-+) mangleIdentifier $ qualify q

mangleTName :: TaggedName -> Identifier
mangleTName (TagEvent q) = qualifyMangle q +-+ "t"
mangleTName t = qualifyMangle t

mangleEv :: Event TaggedName -> Identifier
mangleEv (Event evName) = mangleIdentifier $ disqualifyTag evName
mangleEv EventEnter = "enter"
mangleEv EventExit = "exit"
mangleEv EventAny = "any"

transitionFunction :: StateMachineDeclarator TaggedName -> Event TaggedName -> [State TaggedName] -> FunctionDefinition
transitionFunction (StateMachineDeclarator smName) e@EventExit ss =
    makeFunction (fromList [A STATIC, B VOID]) [] f_name params
    (CompoundStatement
    LEFTCURLY
        Nothing
        (Just $ fromList [makeSwitch (fromList [state_var]) cases []])
    RIGHTCURLY)
    where
        evAlone = mangleEv e
        f_name = qualifyMangle (sName smName StateAny, evAlone)
        params = case e of
                    otherwise -> [ParameterDeclaration (fromList [B VOID]) Nothing]
        state_var = (#:) (qualifyMangle (smName, "state")) (:#)
        call_ev_in s n vs = (#:) (apply ((#:) (qualifyMangle (s, n)) (:#)) vs) (:#)
        cases = [((#:) (mangleTName s) (:#), [fromList [call_ev_in s evAlone []]]) | (State s) <- ss]

initializeFunction :: StateMachineDeclarator TaggedName -> State TaggedName -> FunctionDefinition
initializeFunction (StateMachineDeclarator smName) (State s) =
    makeFunction (fromList [A STATIC, B VOID]) [] f_name [ParameterDeclaration (fromList [B VOID]) Nothing]
    (CompoundStatement
    LEFTCURLY
        (Just $ fromList [Declaration
                          (fromList [A STATIC, B (makeEnum "" [init_uninit, init_init])])
                          (Just $ fromList [InitDeclarator (Declarator Nothing (IDirectDeclarator init_var)) (Just $ Pair EQUAL (AInitializer ((#:) init_uninit (:#))))])
                           SEMICOLON])
        (Just $ fromList [SStatement $ IF LEFTPAREN (fromList [init_check]) RIGHTPAREN (CStatement $ CompoundStatement
                                       LEFTCURLY
                                            Nothing
                                            (Just $ fromList [EStatement $ ExpressionStatement (Just $ fromList [se]) SEMICOLON | se <- side_effects])
                                       RIGHTCURLY)
                                       Nothing])
    RIGHTCURLY)
    where
        state_var = (#:) (qualifyMangle (smName, "state")) (:#)
        f_name = qualifyMangle (smName, "initialize")
        init_var = "initialized"
        init_init = "INITIALIZED"
        init_uninit = "UNINITIALIZED"
        assign_state = state_var `ASSIGN` ((#:) (mangleTName s) (:#))
        enter_f = (#:) (qualifyMangle (s, "enter")) (:#)
        call_enter = (#:) (apply enter_f []) (:#)
        init_check = (#:) ((#:) init_init (:#) `NOTEQUAL` (#:) init_var (:#)) (:#)
        init_set = (#:) init_var (:#) `ASSIGN` (#:) init_init (:#)
        side_effects = [assign_state, call_enter, init_set]

sName :: TaggedName -> State TaggedName -> QualifiedName
sName _ (State s) = qualify s
sName smName StateAny  = qualify (smName, "ANY_STATE")

handleStateEventFunction :: StateMachineDeclarator TaggedName -> State TaggedName -> Happening -> State TaggedName -> SymbolTable -> FunctionDefinition
handleStateEventFunction sm@(StateMachineDeclarator smName) st h st' syms =
    makeFunction (fromList [A STATIC, B VOID]) [] f_name params
    (CompoundStatement
    LEFTCURLY
        Nothing
        (if null side_effects then Nothing else Just $ fromList [EStatement $ ExpressionStatement (Just $ fromList [se]) SEMICOLON | se <- side_effects])
    RIGHTCURLY)
    where
        destStateMangledName = qualifyMangle $ sName smName st'
        params = case event h of
                    (Event t) -> [ParameterDeclaration (fromList [C CONST, B $ TypeSpecifier $ mangleTName t])
                                  (Just $ Left $ Declarator (Just $ fromList [POINTER Nothing]) $ IDirectDeclarator event_var)]
                    otherwise -> [ParameterDeclaration (fromList [B VOID]) Nothing]
        f_name = qualifyMangle (sName smName st, mangleEv $ event h)
        event_var = "e"
        event_ex = (#:) event_var (:#)
        dest_state = (#:) destStateMangledName (:#)
        state_var = (#:) (qualifyMangle (smName, "state")) (:#)
        assign_state = (state_var `ASSIGN` dest_state)
        exit_f = (#:) (qualifyMangle (sName smName st, "exit")) (:#)
        enter_f = (#:) (qualifyMangle (sName smName st', "enter")) (:#)
        call_exit = (#:) (apply exit_f []) (:#)
        call_enter = (#:) (apply enter_f []) (:#)

        isEventTy :: Ty -> Event TaggedName -> Bool
        isEventTy a (Event e) = a == snd (syms ! e)
        isEventTy _ _ = False

        psOf (Void :-> _) = []
        psOf (p    :-> _) = [if isEventTy p (event h) then event_ex else (#:) "0" (:#)]
        apply_se (f, FuncTyped _) = undefined -- See ticket #15, harder than it seems at first.
        apply_se (f, _) = (#:) (apply ((#:) (mangleTName f) (:#)) (psOf (snd $ syms ! f))) (:#)
        side_effects = case h of
                          (Happening _ ses [])                        -> [apply_se se | se <- ses] ++ [call_exit, assign_state, call_enter]
                          (Happening _ ses fs) | elem NoTransition fs -> [apply_se se | se <- ses]

handleEventFunction :: StateMachineDeclarator TaggedName -> Event TaggedName -> [(State TaggedName, (State TaggedName, Event TaggedName))] -> [State TaggedName] -> FunctionDefinition
handleEventFunction (StateMachineDeclarator smName) e@(Event evName) ss unss =
    makeFunction (fromList [B VOID]) [] f_name params
    (CompoundStatement
    LEFTCURLY
        Nothing
        (Just $ fromList [EStatement $ ExpressionStatement (Just $ fromList [call_initialize]) SEMICOLON,
                          makeSwitch (fromList [state_var]) cases defaults])
    RIGHTCURLY)
    where
        evAlone = mangleEv e
        f_name = qualifyMangle evName
        params = case e of
                    (Event t) -> [ParameterDeclaration (fromList [C CONST, B $ TypeSpecifier $ mangleTName t])
                                  (Just $ Left $ Declarator (Just $ fromList [POINTER Nothing]) $ IDirectDeclarator event_var)]
        event_var = "e"
        event_ex = (#:) event_var (:#)
        state_var = (#:) (qualifyMangle (smName, "state")) (:#)
        unhandled = (#:) (qualifyMangle (qualify (smName, "UNHANDLED_EVENT"), evAlone)) (:#)
        initialize = (#:) (qualifyMangle (smName, "initialize")) (:#)
        call_unhandled = (#:) (apply unhandled [event_ex]) (:#)
        call_initialize = (#:) (apply initialize []) (:#)
        call_ev_in s ev vs = (#:) (apply ((#:) (qualifyMangle (s, mangleEv ev)) (:#)) vs) (:#)
        esOf EventAny = []
        esOf e' | e == e' = [(#:) event_var (:#)]
        cases = [((#:) (mangleTName s) (:#), [fromList [call_ev_in s' ev (esOf ev)]]) | (State s, (State s', ev)) <- ss]
             ++ [((#:) (mangleTName s) (:#), [fromList [call_unhandled]]) | (State s) <- unss]
        defaults = [fromList [call_unhandled]]

unhandledEventFunction :: Bool -> [(State TaggedName, Event TaggedName)] -> StateMachineDeclarator TaggedName -> Event TaggedName -> FunctionDefinition
unhandledEventFunction debug handler (StateMachineDeclarator smName) e@(Event evName) =
    makeFunction (fromList [A STATIC, B VOID]) [] f_name [ParameterDeclaration (fromList [C CONST, B $ TypeSpecifier event_type])
                                                          (Just $ Left $ Declarator (Just $ fromList [POINTER Nothing]) $ IDirectDeclarator event_var)]
    (CompoundStatement
    LEFTCURLY
        (if (not $ null handler) || not debug then Nothing else
          (Just $ fromList [Declaration (fromList [C CONST, B CHAR]) 
                                        (Just $ fromList [InitDeclarator (Declarator (Just $ fromList [POINTER Nothing]) $ IDirectDeclarator name_var)
                                                          (Just $ Pair EQUAL $ AInitializer evname_e)])
                                        SEMICOLON]))
        (Just $ fromList [EStatement $ ExpressionStatement (Just $ fromList [call_handler_f]) SEMICOLON])
    RIGHTCURLY)
    where
        name_var = "event_name"
        name_ex = (#:) name_var (:#)
        evAlone = mangleEv e
        evname_e = (#:) (show $ disqualifyTag evName) (:#)
        f_name = qualifyMangle (qualify (smName, "UNHANDLED_EVENT"), evAlone)
        event_type = mangleTName evName
        event_var = "e"
        assert_f = (#:) (if debug then "printf_assert" else "assert") (:#)
        assert_s = (#:) (show (disqualifyTag smName ++ "[%s]: Unhandled event \"%s\"\n")) (:#)
        sname_f  = (#:) (qualifyMangle (smName, "State_name")) (:#)
        state_var = (#:) (qualifyMangle (smName, "state")) (:#)
        call_sname_f = (#:) (apply sname_f [state_var]) (:#)
        call_assert_f = (#:) (apply assert_f (if debug then [assert_s, call_sname_f, name_ex] else [])) (:#)
        handle_f s e = (#:) (qualifyMangle (sName smName s, mangleEv e)) (:#)
        esOf EventAny = []
        esOf e' | e == e' = [(#:) event_var (:#)]
        call_handler_f = case handler of
                         [(s, e)] -> (#:) (apply (handle_f s e) (esOf e)) (:#)
                         [] -> call_assert_f

stateNameFunction :: StateMachineDeclarator TaggedName -> [State TaggedName] -> FunctionDefinition
stateNameFunction (StateMachineDeclarator smName) ss =
    makeFunction (fromList [A STATIC, C CONST, B CHAR]) [POINTER Nothing] f_name
                                           [ParameterDeclaration (fromList [B $ TypeSpecifier smEnum])
                                            (Just $ Left $ Declarator Nothing $ IDirectDeclarator state_var)] 
    (CompoundStatement
    LEFTCURLY
        (Just $ fromList [Declaration (fromList [A STATIC, C CONST, B CHAR]) 
                                      (Just $ fromList [InitDeclarator (Declarator (Just $ fromList [POINTER $ Just $ fromList [CONST]]) $
                                                                        CDirectDeclarator (IDirectDeclarator names_var) LEFTSQUARE Nothing RIGHTSQUARE)
                                                        (Just $ Pair EQUAL (LInitializer LEFTCURLY
                                                                                         (fromList [AInitializer ((#:) (show $ disqualifyTag s) (:#)) | (State s) <- ss])
                                                                                         Nothing
                                                                                         RIGHTCURLY))])
                                      SEMICOLON,
                          Declaration (fromList [A STATIC, C CONST, B UNSIGNED, B INT])
                                      (Just $ fromList [InitDeclarator (Declarator Nothing (IDirectDeclarator count_var))
                                                        (Just $ Pair EQUAL (AInitializer names_count_e ))])
                                      SEMICOLON])
        (Just $ fromList [JStatement $ RETURN (Just $ fromList [safe_array_index_e]) SEMICOLON])
    RIGHTCURLY)
    where
        smEnum = qualifyMangle (smName, "State")
        count_var = "state_count"
        state_var = "s"
        names_var = "state_name"
        f_name = qualifyMangle (smName, "State_name")
        names_size_e = (#:) (SIZEOF $ Right $ Trio LEFTPAREN (TypeName (fromList [Left $ TypeSpecifier names_var]) Nothing) RIGHTPAREN) (:#)
        ptr_size_e = (#:) (SIZEOF $ Right $ Trio LEFTPAREN (TypeName (fromList [Right CONST, Left CHAR])
                                                                     (Just $ AbstractDeclarator $ This $ fromList [POINTER Nothing])) RIGHTPAREN) (:#)
        names_count_e = (#:) (names_size_e `DIV` ptr_size_e) (:#)
        count_var_e = (#:) count_var (:#)
        state_var_e = (#:) state_var (:#)
        names_var_e = (#:) names_var (:#)
        default_state = (#:) (show "INVALID_STATE") (:#)
        bounds_check_e = (#:) (state_var_e `LESS_THAN` count_var_e) (:#)
        array_index_e = (#:) (EPostfixExpression names_var_e LEFTSQUARE (fromList [(#:) state_var_e (:#)]) RIGHTSQUARE) (:#)
        safe_array_index_e = (#:) (bounds_check_e `QUESTION` (Trio (fromList [array_index_e]) COLON default_state)) (:#)

currentStateNameFunction :: Bool -> StateMachineDeclarator TaggedName -> FunctionDefinition
currentStateNameFunction debug (StateMachineDeclarator smName) = 
    makeFunction (fromList [C CONST, B CHAR]) [POINTER Nothing] f_name [ParameterDeclaration (fromList [B VOID]) Nothing]
    (CompoundStatement
    LEFTCURLY
        Nothing
        (Just $ fromList [JStatement $ RETURN (Just $ fromList [if debug then call_sname_f else ((#:) (show "") (:#))]) SEMICOLON])
    RIGHTCURLY)
    where
        f_name = qualifyMangle (smName, "Current_state_name")
        sname_f  = (#:) (qualifyMangle (smName, "State_name")) (:#)
        state_var = (#:) (qualifyMangle (smName, "state")) (:#)
        call_sname_f = (#:) (apply sname_f [state_var]) (:#)

handleStateEventDeclaration :: StateMachineDeclarator TaggedName -> State TaggedName -> Event TaggedName -> Declaration
handleStateEventDeclaration (StateMachineDeclarator smName) st e =
    Declaration
    (fromList [A STATIC, B VOID])
    (Just $ fromList [InitDeclarator (makeFunctionDeclarator [] f_name params) Nothing])
    SEMICOLON
    where
        params = case e of
                    (Event t) -> [ParameterDeclaration (fromList [C CONST, B $ TypeSpecifier $ mangleTName t])
                                  (Just $ Right $ AbstractDeclarator $ This $ fromList [POINTER Nothing])]
                    otherwise -> [ParameterDeclaration (fromList [B VOID]) Nothing]
        f_name = qualifyMangle (sName smName st, mangleEv e)

stateVarDeclaration :: StateMachineDeclarator TaggedName -> State TaggedName -> Declaration
stateVarDeclaration (StateMachineDeclarator smName) (State s) =
    Declaration
    (fromList [A STATIC, B $ TypeSpecifier smEnum])
    (Just $ fromList [InitDeclarator (Declarator Nothing (IDirectDeclarator state_var)) 
                                     (Just $ Pair EQUAL $ AInitializer ((#:) sMangled (:#)))])
    SEMICOLON
    where
        smEnum = qualifyMangle (smName, "State")
        sMangled = mangleTName s
        state_var = qualifyMangle (smName, "state")

stateEnum :: StateMachineDeclarator TaggedName -> [State TaggedName] -> Declaration
stateEnum (StateMachineDeclarator smName) ss =
    Declaration
    (fromList [A TYPEDEF,
               B (makeEnum smEnum ssMangled)])
    (Just $ fromList [InitDeclarator (Declarator Nothing (IDirectDeclarator smEnum)) Nothing])
    SEMICOLON
    where
        smEnum = qualifyMangle (smName, "State")
        ssMangled = [mangleTName s | (State s) <- ss]

makeSwitch :: Expression -> [(ConstantExpression, [Expression])] -> [Expression] -> Statement
makeSwitch var cs ds =
    SStatement $ SWITCH LEFTPAREN var RIGHTPAREN $ CStatement $ CompoundStatement LEFTCURLY
    Nothing
    (Just $ fromList $ concat [(LStatement $ CASE l COLON $ frst_stmt ss) : rest_stmt ss | (l, ss) <- cs]
                              ++ (LStatement $ DEFAULT COLON $ frst_stmt ds) : rest_stmt ds)
    RIGHTCURLY
    where
        estmt e = EStatement $ ExpressionStatement (Just e) SEMICOLON
        frst_stmt (e:_) = estmt e
        frst_stmt []    = JStatement $ BREAK SEMICOLON
        rest_stmt (_:es) = map estmt es ++ [JStatement $ BREAK SEMICOLON]
        rest_stmt []     = []

makeEnum :: Identifier -> [Identifier] -> TypeSpecifier
makeEnum smName [] = ENUM (Left $ smName)
makeEnum smName ss = 
    ENUM (Right (Quad (if null smName then Nothing else Just $ smName)
    LEFTCURLY
    (fromList [Enumerator s Nothing | s <- ss])
    RIGHTCURLY))

eventStruct :: TaggedName -> Ty -> Declaration
eventStruct name (Ty ty) =
    Declaration
    (fromList [A TYPEDEF,
               B (makeStruct (mangleTName ty) [])])
    (Just $ fromList [InitDeclarator (Declarator Nothing (IDirectDeclarator $ mangleTName name)) Nothing])
    SEMICOLON

makeStruct :: Identifier -> [(SpecifierQualifierList, Identifier)] -> TypeSpecifier
makeStruct name [] = STRUCT (Left $ name)
makeStruct name ss = 
    STRUCT (Right (Quad (Just $ name)
    LEFTCURLY
    (fromList [StructDeclaration sqs (fromList [StructDeclarator $ This $ Declarator Nothing $ IDirectDeclarator id]) SEMICOLON | (sqs, id) <- ss])
    RIGHTCURLY))

makeFunctionDeclarator :: [Pointer] -> Identifier -> [ParameterDeclaration] -> Declarator
makeFunctionDeclarator ps f_name params =
    Declarator (if null ps then Nothing else Just $ fromList ps)
        $ PDirectDeclarator
          (IDirectDeclarator f_name)
          LEFTPAREN
          (Just $ Left $ ParameterTypeList (fromList params) Nothing)
          RIGHTPAREN

makeFunctionDeclaration :: TaggedName -> (Binding, Ty) -> Declaration
makeFunctionDeclaration n (b, p :-> r) =
    Declaration
    (fromList $ binding ++ [B result])
    (Just $ fromList [InitDeclarator (makeFunctionDeclarator ps f_name params) Nothing])
    SEMICOLON
    where
        binding = case b of External -> [A EXTERN]; _ -> []
        f_name = mangleTName n
        xlate_r  Void  = (VOID, [])
        xlate_r (Ty t) = (TypeSpecifier $ mangleTName t, [POINTER Nothing])
        xlate_ps (Void) = [ParameterDeclaration (fromList [B VOID]) Nothing]
        xlate_ps (Ty t) = [ParameterDeclaration (fromList [C CONST, B $ TypeSpecifier $ mangleTName t])
                               (Just $ Right $ AbstractDeclarator (This $ fromList [POINTER Nothing]))]
        xlate_ps (p :-> Void) = xlate_ps p
        xlate_ps (p :-> Ty _) = xlate_ps p
        xlate_ps (p :-> p')   = xlate_ps p ++ xlate_ps p'
        translate t = (xlate_ps t, xlate_r $ resultOf t)
        (params, (result, ps)) = translate (p :-> r)

makeFunction :: DeclarationSpecifiers -> [Pointer] -> Identifier -> [ParameterDeclaration] -> CompoundStatement -> FunctionDefinition
makeFunction dss ps f_name params body =
    Function
    (Just dss)
    (makeFunctionDeclarator ps f_name params)
    Nothing
    body

instance Backend CStaticOption where
    options = ("c",
               [Option [] ["o"] (ReqArg OutFile "FILE")
                 "The name of the target file if not derived from source file.",
                Option [] ["h"] (ReqArg Header "FILE")
                 "The name of the target header file if not derived from source file.",
                Option [] ["ext_h"] (ReqArg ExtFile "FILE")
                 "The name of the target ext header file if not derived from source file.",
                Option [] ["no-debug"] (NoArg NoDebug)
                 "Don't generate debugging information"])
    generate os gswust outputTarget = sequence $ [writeTranslationUnit (renderHdr hdr []) (headerName os),
                                         writeTranslationUnit (renderSrc src [extHdrName os, headerName os]) (outputName os)]
                                         ++ [writeTranslationUnit (renderHdr ext [headerName os]) (extHdrName os) | not $ null tue]
        where src = fromList $ concat tus
              ext = fromList tue
              hdr = fromList tuh
              tuh = [ExternalDeclaration $ Right $ eventStruct name ty | (name, (Resolved, ty@(Ty _))) <- Solver.toList syms]
                    ++ [ExternalDeclaration $ Right $ makeFunctionDeclaration name (Resolved, ftype) | (name, (Resolved, ftype@(_ :-> _))) <- Solver.toList syms]
                    ++ [ExternalDeclaration $ Right $ makeFunctionDeclaration name (External, ftype) | (name, ftype) <- externs]
              tue = [ExternalDeclaration $ Right $ makeFunctionDeclaration name (External, ftype) | (name, (External, ftype@(_ :-> _))) <- Solver.toList syms]
              tus = [[ExternalDeclaration $ Right $ stateEnum sm $ states g]
                     ++ [ExternalDeclaration $ Right $ stateVarDeclaration sm $ initial g]
                     ++ [ExternalDeclaration $ Right $ handleStateEventDeclaration sm s EventExit | (_, EnterExitState {st = s@StateAny}) <- labNodes g]
                     ++ [ExternalDeclaration $ Right $ handleStateEventDeclaration sm s e
                         | (n, EnterExitState {st = s}) <- labNodes g, e <- (map (event . edgeLabel) $ out g n), case s of State _ -> True; StateAny -> True; _ -> False]
                     ++ (if debug then [ExternalDeclaration $ Left $ stateNameFunction sm $ states g] else [])
                     ++ [ExternalDeclaration $ Left $ currentStateNameFunction debug sm]
                     ++ [ExternalDeclaration $ Left $ transitionFunction sm EventExit
                         [st | (n, EnterExitState {st, ex = (_:_)}) <- labNodes g, n `notElem` finalStates g] | (_, EnterExitState {st = StateAny}) <- labNodes g]
                     ++ [ExternalDeclaration $ Left $ unhandledEventFunction debug (any_handler e g) sm e | e <- events g]
                     ++ [ExternalDeclaration $ Left $ initializeFunction sm $ initial g]
                     ++ [ExternalDeclaration $ Left $ handleEventFunction sm e (s_handlers e g) (unhandled e g) | e <- events g]
                     ++ [ExternalDeclaration $ Left $ handleStateEventFunction sm s h s' syms
                         | (n, EnterExitState {st = s}) <- labNodes g, (_, n', h) <- out g n, Just EnterExitState {st = s'} <- [lab g n'], case s of State _ -> True; StateAny -> True; _ -> False, case s' of State _ -> True; StateAny -> True; _ -> False]
                     | (sm, g) <- gs'']
              gs'' = [(sm, insEdges [(n, n, Happening EventEnter en [NoTransition])
                                     | (n, EnterExitState {en, st = State _}) <- labNodes $ delNodes [n | n <- nodes g, (_, _, Happening EventEnter _ _) <- out g n] g] g)
                      | (sm, g) <- gs']
              gs'  = [(sm, insEdges [(n, n, Happening EventExit ex [NoTransition])
                                     | (n, EnterExitState {st = State _, ex}) <- labNodes $ delNodes (finalStates g ++ [n | n <- nodes g, (_, _, Happening EventExit _ _) <- out g n]) g] g)
                      | (sm, g) <- gs]
              gs = [(smd, g) | (Annotated _ smd, g) <- fst gswust]
              syms :: SymbolTable
              syms = insertExternalSymbol "printf_assert" ["char", "char", "char"] "" $
                     insertExternalSymbol "assert" [] "" (snd gswust)
              externs = [(TagFunction $ qualify (smName, "Current_state_name"), Void :-> (Ty $ TagBuiltin $ qualify "const char")) | ((StateMachineDeclarator smName), _) <- gs'']
              initial g = head [st ese | (n, EnterExitState {st = StateEntry}) <- labNodes g, n' <- suc g n, (Just ese) <- [lab g n']]
              states g = [st ees | (_, ees) <- labNodes g]
              s_handlers e g = [(s, h) | (s, Just h@(State _, _)) <- toList (handlers e g)]
              unhandled e g = [s | (s, Just (StateAny, _)) <- toList (handlers e g)] ++ [s | (s, Nothing) <- toList (handlers e g)]
              any_handler e g = nub [h | (_, Just h@(StateAny, _)) <- toList (handlers e g)]
              events g = nub $ sort [e | (_, _, Happening {event=e@(Event _)}) <- labEdges g]
              edgeLabel (_, _, l) = l
              inc ^++ src = (liftM (++src)) inc
              writeTranslationUnit render fp = (render fp) >>= (writeFile fp) >> (return fp)
              renderHdr u includes fp = hdrLeader includes fp ^++ (renderPretty u ++ hdrTrailer)
              renderSrc u includes fp = srcLeader includes fp ^++ (renderPretty u ++ srcTrailer)
              getFirstOrDefault :: ([a] -> b) -> b -> [a] -> b
              getFirstOrDefault _ d     [] = d
              getFirstOrDefault f _ (x:xs) = f xs
              outputFileName ((OutFile f):_) = f
              outputFileName xs = getFirstOrDefault outputFileName ((dropExtension outputTarget) <.> "c") xs
              outputName = normalise . outputFileName
              headerFileName ((Header f):_) = f
              headerFileName xs = getFirstOrDefault headerFileName ((dropExtension outputTarget) <.> "h") xs
              headerName = normalise . headerFileName
              extHdrFileName ((ExtFile f):_) = f
              extHdrFileName xs = getFirstOrDefault extHdrFileName (((dropExtension outputTarget) ++ "_ext") <.> "h") xs
              extHdrName = normalise . extHdrFileName
              doDebug ((NoDebug):_) = False
              doDebug xs = getFirstOrDefault doDebug True xs
              genIncludes includes includer = liftM concat $ sequence $ map (mkInclude includer) includes
              mkInclude includer include =
                do
                  relativeInclude <- relPath (takeDirectory includer) include
                  return $ concat ["#include \"", relativeInclude, "\"\n"]
              srcLeader = genIncludes
              srcTrailer = ""
              reinclusionName fp = concat ["__", map (\a -> (if a == '.' then '_' else a)) (takeFileName fp), "__"]
              hdrLeader includes fp =
                do
                  gennedIncludes <- genIncludes includes fp
                  return $ concat ["#ifndef ", reinclusionName fp, "\n", "#define ", reinclusionName fp, "\n",
                                   gennedIncludes]
              hdrTrailer = "#endif\n"
              debug = doDebug os
