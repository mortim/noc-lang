{-# LANGUAGE RankNTypes #-}

module Language.Noc.Runtime.Prelude where

import Control.Monad.RWS
import Control.Monad.State
import Language.Noc.Runtime.Internal
import Language.Noc.Syntax.AST
import Control.Monad.Except (throwError)
import qualified Data.Text as T (pack,unpack,Text)
import qualified Data.Map as M (fromList,keys)
import Control.Exception (try, SomeException)
import qualified Data.Text.IO as TIO (readFile,getLine)
import System.IO
import Data.Fixed (mod')
import Text.Read (readMaybe)

----------------------------------------------------

prelude :: Env 
prelude = M.fromList [
  -- Combinators 
  (T.pack "dup", Constant $ PrimVal builtinDup),
  (T.pack "pop", Constant $ PrimVal builtinPop),
  (T.pack "zap", Constant $ PrimVal builtinZap),
  (T.pack "cat", Constant $ PrimVal builtinCat),
  (T.pack "rotN", Constant $ PrimVal builtinRotN),
  -- Arithmetic operators
  (T.pack "+", Constant $ PrimVal $ builtinOp (+)),
  (T.pack "-", Constant $ PrimVal $ builtinOp (-)),
  (T.pack "*", Constant $ PrimVal $ builtinOp (*)),
  (T.pack "/", Constant $ PrimVal $ builtinDiv),
  (T.pack "%", Constant $ PrimVal $ builtinMod),
  -- I/O
  (T.pack "print", Constant $ PrimVal builtinPrint),
  (T.pack "putstr", Constant $ PrimVal builtinPutStr),
  (T.pack "read", Constant $ PrimVal builtinReadFile),
  (T.pack "ask", Constant $ PrimVal builtinAsk),
  (T.pack "write", Constant $ PrimVal builtinWrite),
  -- Quote
  (T.pack "unquote", Constant $ PrimVal builtinUnquote),
  (T.pack "pushr", Constant $ PrimVal builtinPushr),
  (T.pack "popr", Constant $ PrimVal builtinPopr),
  -- Other
  (T.pack "id", Constant $ PrimVal builtinId),
  (T.pack "str", Constant $ PrimVal builtinStr),
  (T.pack "int", Constant $ PrimVal builtinInt),
  (T.pack "float", Constant $ PrimVal builtinFloat),
  (T.pack "case", Constant $ PrimVal builtinCase),
  (T.pack "_", Constant $ PrimVal builtinAnyMatch)
  ]

----------------------------------------------------

builtinOp :: (forall a. Num a => a -> a -> a) -> Eval ()
builtinOp operator = do
    v1 <- pop
    v2 <- pop
    case (v1,v2) of
        ((FloatVal v1'),(FloatVal v2')) -> push $ FloatVal $ operator v2' v1'
        ((IntVal v1'),(IntVal v2')) -> push $ IntVal $ operator v2' v1'
        ((FloatVal v1'),(IntVal v2')) -> push $ FloatVal $ operator (fromIntegral v2') v1'
        ((IntVal v1'),(FloatVal v2')) -> push $ FloatVal $ operator v2' (fromIntegral v1')
        _ -> throwError $ TypeError "cannot operate with different types."

----------------------------------------------------

builtinDiv :: Eval ()
builtinDiv = do
    v1 <- pop
    v2 <- pop
    case (v1,v2) of
        ((FloatVal v1'),(FloatVal v2')) -> operateDiv v1' v2' 
        ((IntVal v1'),(IntVal v2')) -> operateDiv (fromIntegral v1') (fromIntegral v2')
        ((FloatVal v1'),(IntVal v2')) -> operateDiv v1' (fromIntegral v2') 
        ((IntVal v1'),(FloatVal v2')) -> operateDiv (fromIntegral v1') v2'
        _ -> throwError $ TypeError "cannot operate with different types."
    where operateDiv v1 v2 = case v1 of
                        0 -> throwError $ ZeroDivisionError $ "cannot divide by 0."
                        _ -> push $ FloatVal $ (/) v2 v1
    

builtinMod :: Eval ()
builtinMod = do
    v1 <- pop
    v2 <- pop
    case (v1,v2) of
        ((FloatVal v1'),(FloatVal v2')) -> operateMod v1' v2'
        ((IntVal v1'),(IntVal v2')) -> operateMod (fromIntegral v1') (fromIntegral v2')
        ((FloatVal v1'),(IntVal v2')) -> operateMod v1' (fromIntegral v2') 
        ((IntVal v1'),(FloatVal v2')) -> operateMod (fromIntegral v1') v2'
        _ -> throwError $ TypeError "cannot operate with different types."
    where operateMod v1 v2 = case v1 of
                        0 -> throwError $ ZeroDivisionError $ "cannot divide by 0."
                        _ -> push $ FloatVal $ v2 `mod'` v1
        

----------------------------------------------------

builtinDup :: Eval ()
builtinDup = do
    v1 <- pop
    push v1 >> push v1
    
----------------------------------------------------

builtinPop :: Eval ()
builtinPop = do
    v1 <- pop
    return ()

----------------------------------------------------

builtinZap :: Eval ()
builtinZap = put [] >> return ()

----------------------------------------------------

builtinCat :: Eval ()
builtinCat = do
    v1 <- pop
    v2 <- pop
    case (v1,v2) of
        ((QuoteVal a),(QuoteVal b)) -> push $ (QuoteVal $ b ++ a)
        ((StringVal a),(StringVal b)) -> push $ (StringVal $ b <> a)
        _ -> throwError $ TypeError "cannot cat with different types or concat functions,floats."

----------------------------------------------------

builtinRotN :: Eval ()
builtinRotN = do
    n <- pop
    case n of
        (IntVal x) -> do
            stack <- get
            let n = fromIntegral x
            let rot = take n $ reverse stack
            put $ (initN n stack) <> rot
        _ -> throwError $ TypeError "the parameter isn't an int."

----------------------------------------------------

builtinUnquote :: Eval ()
builtinUnquote = do
    v1 <- pop
    case v1 of
        ((QuoteVal x)) -> evalExpr x
        _ -> throwError $ TypeError "can only unquote with a quotation."
            
----------------------------------------------------

builtinPopr :: Eval ()
builtinPopr = do
    env <- ask
    v1 <- pop
    case v1 of
        ((QuoteVal x)) -> case reverse x of
            ((WordAtom y):ys) -> (push $ QuoteVal $ reverse ys) >> (evalWord y env)
            (y:ys) -> (push $ QuoteVal $ reverse ys) >> (push $ readValue y)
        _ -> throwError $ TypeError "can only popr with a quotation."

----------------------------------------------------

builtinPrint :: Eval ()
builtinPrint = do
    v <- pop
    case v of
        (StringVal x) -> (liftIO $ print x) >> return ()
        (FloatVal x) -> (liftIO $ print x) >> return ()
        (IntVal x) -> (liftIO $ print x) >> return ()
        (BoolVal x) -> (liftIO $ print x) >> return ()
        _ -> throwError $ TypeError "can only print with strings,floats,integers,bool."

----------------------------------------------------

builtinPutStr :: Eval ()
builtinPutStr = do
    v <- pop
    case v of
        (StringVal x) -> (liftIO $ putStr $ T.unpack $ x) >> return ()
        _ -> throwError $ TypeError "can only putstr with strings."

----------------------------------------------------

builtinReadFile :: Eval ()
builtinReadFile = do
    path <- pop
    case path of
        (StringVal x) -> do
                            content <- liftIO (try $ TIO.readFile (T.unpack x) :: IO (Either SomeException T.Text))
                            case content of
                                (Left err) -> throwError $ FileNotFoundError "the file does not exist (no such file or directory)"
                                (Right succ) -> push $ StringVal succ
        _ -> throwError $ TypeError "the parameter is not string."

----------------------------------------------------

builtinAsk :: Eval ()
builtinAsk = do
    msg <- pop
    case msg of
        (StringVal x) -> do
            liftIO $ putStr $ T.unpack x
            liftIO $ hFlush stdout
            inp <- liftIO $ TIO.getLine
            push $ StringVal inp
        _ -> throwError $ TypeError "the parameter is not string."

----------------------------------------------------

builtinPushr :: Eval ()
builtinPushr = do
    v <- pop
    l <- pop
    case l of
        (QuoteVal l') -> push $ QuoteVal (l' <> [readAtom v])
        _ -> throwError $ TypeError "can only pushr with a quotation."

----------------------------------------------------

builtinWrite :: Eval ()
builtinWrite = do
    content <- pop
    path <- pop
    case path of
        (StringVal p) -> case content of
            (StringVal c) -> liftIO $ writeFile (T.unpack p) (T.unpack c)
            _ -> throwError $ TypeError "the first parameter is not string."
        _ -> throwError $ TypeError "the second parameter is not string."

----------------------------------------------------

builtinId :: Eval ()
builtinId = do
    v <- pop
    push v

----------------------------------------------------

builtinStr :: Eval ()
builtinStr = do
    v <- pop
    case v of
        (StringVal x) -> push $ StringVal x
        (FloatVal x) -> push $ StringVal $ T.pack $ show x
        (IntVal x) -> push $ StringVal $ T.pack $ show x
        (BoolVal x) -> push $ StringVal $ T.pack $ show x
        _ -> throwError $ TypeError "can only str with str,float,int,bool"
    
----------------------------------------------------

builtinInt :: Eval ()
builtinInt = do
    v <- pop
    case v of
        (IntVal x) -> push $ IntVal x
        (StringVal x) -> case readMaybe (T.unpack x) :: Maybe Integer of
            (Just v) -> push $ IntVal v
            Nothing -> throwError $ ValueError "the value is not a integer."
        _ -> throwError $ TypeError "can only int with int,str"

----------------------------------------------------

builtinFloat :: Eval ()
builtinFloat = do
    v <- pop
    case v of
        (IntVal x) -> push $ FloatVal $ fromIntegral x
        (FloatVal x) -> push $ FloatVal x
        (StringVal x) -> case readMaybe (T.unpack x) :: Maybe Double of
            (Just v) -> push $ FloatVal v
            Nothing -> throwError $ ValueError "the value is not a integer."
        _ -> throwError $ TypeError "can only float with int,float,str"

----------------------------------------------------

builtinAnyMatch :: Eval ()
builtinAnyMatch = push $ QuoteVal [WordAtom "_"]

cases :: Value -> Integer -> Eval ()
cases _ 0 = throwError $ ValueError "Non-exhaustive patterns in case"
cases case' n = do
    pattern' <- pop
    case pattern' of
        (QuoteVal [QuoteAtom p, QuoteAtom exprs]) -> do
            evalExpr p
            pat <- pop
            case (case', pat) of
                (StringVal a, StringVal b) -> runCase a b exprs       
                (IntVal a, IntVal b) -> runCase a b exprs
                (FloatVal a, FloatVal b) -> runCase a b exprs
                (BoolVal a, BoolVal b) -> runCase a b exprs
                --
                (_, QuoteVal [WordAtom "_"]) -> push case' >> evalExpr exprs
                (StringVal a, _) -> cases case' (n-1)         
                (IntVal a, _)-> cases case' (n-1)
                (FloatVal a, _) -> cases case' (n-1)
                (BoolVal a, _) -> cases case' (n-1)
                _ -> popN (n-1)
        _ ->  throwError $ TypeError "lack of quotes in one of the cases."
    where runCase a b exprs = if a == b then popN (n-1) >> evalExpr exprs else cases case' (n-1)


builtinCase :: Eval ()
builtinCase = do
    patterns <- pop
    toCase <- pop
    case toCase of
        (QuoteVal x) -> case patterns of
            (QuoteVal y) -> do
                let lenPatterns = fromIntegral $ length y
                -- case
                evalExpr x
                caseVal <- pop
                --- match case with one of the patterns
                evalExpr y
                (push $ IntVal lenPatterns) >> builtinRotN
                -- evaluate case
                cases caseVal lenPatterns

            _ -> throwError $ TypeError "the patterns are not quote."
        _ -> throwError $ TypeError "the value to case is not quote."