{-# LANGUAGE RankNTypes #-}

{-| This module provides @pipes@ utilities for \"byte streams\", which are
    streams of strict 'BS.ByteString's chunks.  Use byte streams to interact
    with both 'IO.Handle's and lazy 'ByteString's.

    To stream to or from 'IO.Handle's, use 'fromHandle' or 'toHandle'.  For
    example, the following program copies data from one file to another:

> import Pipes
> import qualified Pipes.ByteString as P
> import System.IO
>
> main =
>     withFile "inFile.txt"  ReadMode  $ \hIn  ->
>     withFile "outFile.txt" WriteMode $ \hOut ->
>     runEffect $ P.fromHandle hIn >-> P.toHandle hOut

    You can also stream to and from 'stdin' and 'stdout' using the predefined
    'stdin' and 'stdout' proxies, like in the following \"echo\" program:

> main = runEffect $ P.stdin >-> stdout.P

    You can also translate pure lazy 'BL.ByteString's to and from proxies:

> import qualified Data.ByteString.Lazy.Char8 as BL
>
> main = runEffect $ P.fromLazy (BL.pack "Hello, world!\n") >-> P.stdout

    In addition, this module provides many functions equivalent to lazy
    'ByteString' functions so that you can transform or fold byte streams.

    Note that functions in this library are designed to operate on streams that
    are insensitive to chunk boundaries.  This means that they may freely split
    chunks into smaller chunks and /discard empty chunks/.  However, they will
    /never concatenate chunks/ in order to provide strict memory-usage
    guarantees.
-}

module Pipes.ByteString (
    -- * Producers
    fromLazy,
    stdin,
    fromHandle,
    hGetSome,
    hGet,

    -- * Servers
    hGetSomeN,
    hGetN,

    -- * Consumers
    stdout,
    toHandle,

    -- * Pipes
    map,
    concatMap,
    take,
    drop,
    takeWhile,
    dropWhile,
    filter,
    elemIndices,
    findIndices,
    scan,

    -- * Folds
    toLazy,
    toLazyM,
    fold,
    head,
    last,
    null,
    length,
    any,
    all,
    maximum,
    minimum,
    elem,
    notElem,
    find,
    index,
    elemIndex,
    findIndex,
    count,

    -- * Splitters
    splitAt,
    chunksOf,

    -- * Transformations
    intersperse,

    -- * Joiners
    intercalate,

    -- * Low-level Parsers
    draw,
    peek,
    isEndOfInput,

    -- * Re-exports
    -- $reexports
    module Pipes.Parse
    ) where

import Control.Monad (liftM, unless)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.State.Strict (StateT)
import Data.Functor.Identity (Identity)
import Pipes
import Pipes.Core (respond, Server')
import qualified Pipes.Prelude as P
import qualified Pipes.Parse as PP
import Pipes.Parse (unDraw, input, concat)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Internal as BLI
import qualified Data.ByteString.Unsafe as BU
import Data.Word (Word8)
import qualified System.IO as IO
import qualified Data.List as List
import Prelude hiding (
    concat,
    head,
    last,
    length,
    map,
    concatMap,
    any,
    all,
    take,
    drop,
    takeWhile,
    dropWhile,
    elem,
    notElem,
    filter,
    null,
    maximum,
    minimum,
    splitAt )


-- | Convert a lazy 'BL.ByteString' into a 'Producer' of strict 'BS.ByteString's
fromLazy :: (Monad m) => BL.ByteString -> Producer' BS.ByteString m ()
fromLazy bs =
   BLI.foldrChunks (\e a -> yield e >> a) (return ()) bs
{-# INLINABLE fromLazy #-}

-- | Stream bytes from 'stdin'
stdin :: MonadIO m => Producer' BS.ByteString m ()
stdin = fromHandle IO.stdin
{-# INLINABLE stdin #-}

-- | Convert a 'IO.Handle' into a byte stream using a default chunk size
fromHandle :: MonadIO m => IO.Handle -> Producer' BS.ByteString m ()
fromHandle = hGetSome BLI.defaultChunkSize
-- TODO: Test chunk size for performance
{-# INLINABLE fromHandle #-}

-- | Convert a handle into a byte stream using a fixed chunk size
hGetSome :: MonadIO m => Int -> IO.Handle -> Producer' BS.ByteString m ()
hGetSome size h = go where
    go = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs <- liftIO (BS.hGetSome h size)
                yield bs
                go
{-# INLINABLE hGetSome #-}

-- | Convert a handle into a byte stream using a fixed chunk size
hGet :: MonadIO m => Int -> IO.Handle -> Producer' BS.ByteString m ()
hGet size h = go where
    go = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs <- liftIO (BS.hGet h size)
                yield bs
                go
{-# INLINABLE hGet #-}

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetSomeN :: MonadIO m => IO.Handle -> Int -> Server' Int BS.ByteString m ()
hGetSomeN h = go where
    go size = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs    <- liftIO (BS.hGetSome h size)
                size2 <- respond bs
                go size2
{-# INLINABLE hGetSomeN #-}

-- | Convert a handle into a byte stream that serves variable chunk sizes
hGetN :: MonadIO m => IO.Handle -> Int -> Server' Int BS.ByteString m ()
hGetN h = go where
    go size = do
        eof <- liftIO (IO.hIsEOF h)
        if eof
            then return ()
            else do
                bs    <- liftIO (BS.hGet h size)
                size2 <- respond bs
                go size2
{-# INLINABLE hGetN #-}

-- | Stream bytes to 'stdout'
stdout :: MonadIO m => Consumer' BS.ByteString m r
stdout = toHandle IO.stdout
{-# INLINABLE stdout #-}

-- | Convert a byte stream into a 'Handle'
toHandle :: MonadIO m => IO.Handle -> Consumer' BS.ByteString m r
toHandle h = for cat (liftIO . BS.hPut h)
{-# INLINABLE toHandle #-}

-- | Apply a transformation to each 'Word8' in the stream
map :: (Monad m) => (Word8 -> Word8) -> Pipe BS.ByteString BS.ByteString m r
map f = P.map (BS.map f)
{-# INLINABLE map #-}

-- | Map a function over the byte stream and concatenate the results
concatMap
    :: (Monad m)
    => (Word8 -> BS.ByteString) -> Pipe BS.ByteString BS.ByteString m r
concatMap f = P.map (BS.concatMap f)
{-# INLINABLE concatMap #-}

-- | @(take n)@ only allows @n@ bytes to pass
take :: (Monad m, Integral a) => a -> Pipe BS.ByteString BS.ByteString m ()
take n0 = go n0 where
    go n
        | n <= 0    = return ()
        | otherwise = do
            bs <- await
            let len = fromIntegral (BS.length bs)
            if (len > n)
                then yield (BU.unsafeTake (fromIntegral n) bs)
                else do
                    yield bs
                    go (n - len)
{-# INLINABLE take #-}

-- | @(dropD n)@ drops the first @n@ bytes
drop :: (Monad m, Integral a) => a -> Pipe BS.ByteString BS.ByteString m r
drop n0 = go n0 where
    go n
        | n <= 0    = cat
        | otherwise = do
            bs <- await
            let len = fromIntegral (BS.length bs)
            if (len >= n)
                then do
                    yield (BU.unsafeDrop (fromIntegral n) bs)
                    cat
                else go (n - len)
{-# INLINABLE drop #-}

-- | Take bytes until they fail the predicate
takeWhile
    :: (Monad m) => (Word8 -> Bool) -> Pipe BS.ByteString BS.ByteString m ()
takeWhile predicate = go where
    go = do
        bs <- await
        case BS.findIndex (not . predicate) bs of
            Nothing -> do
                yield bs
                go
            Just i -> yield (BU.unsafeTake i bs)
{-# INLINABLE takeWhile #-}

-- | Drop bytes until they fail the predicate
dropWhile
    :: (Monad m) => (Word8 -> Bool) -> Pipe BS.ByteString BS.ByteString m r
dropWhile predicate = go where
    go = do
        bs <- await
        case BS.findIndex (not . predicate) bs of
            Nothing -> go
            Just i -> do
                yield (BU.unsafeDrop i bs)
                cat
{-# INLINABLE dropWhile #-}

-- | Only allows 'Word8's to pass if they satisfy the predicate
filter :: (Monad m) => (Word8 -> Bool) -> Pipe BS.ByteString BS.ByteString m r
filter pred = P.map (BS.filter pred)
{-# INLINABLE filter #-}

-- | Store a list of all indices whose elements match the given 'Word8'
elemIndices :: (Monad m, Num n) => Word8 -> Pipe BS.ByteString n m r
elemIndices w8 = findIndices (w8 ==)
{-# INLINABLE elemIndices #-}

-- | Store a list of all indices whose elements satisfy the given predicate
findIndices :: (Monad m, Num n) => (Word8 -> Bool) -> Pipe BS.ByteString n m r
findIndices predicate = go 0
  where
    go n = do
        bs <- await
	each $ List.map (\i -> n + fromIntegral i) (BS.findIndices predicate bs)
        go $! n + fromIntegral (BS.length bs)
{-# INLINABLE findIndices #-}

-- | Strict left scan over the bytes
scan
    :: (Monad m)
    => (Word8 -> Word8 -> Word8)
    -> Word8
    -> Pipe BS.ByteString BS.ByteString m r
scan step begin = go begin
  where
    go w8 = do
        bs <- await
        let bs' = BS.scanl step begin bs
            w8' = BS.last bs'
        yield bs'
        go w8'
{-# INLINABLE scan #-}

{-| Fold a pure 'Producer' of strict 'BS.ByteString's into a lazy
    'BL.ByteString'
-}
toLazy :: Producer BS.ByteString Identity () -> BL.ByteString
toLazy = BL.fromChunks . P.toList
{-# INLINABLE toLazy #-}

{-| Fold an effectful 'Producer' of strict 'BS.ByteString's into a lazy
    'BL.ByteString'

    Note: 'toLazyM' is not an idiomatic use of @pipes@, but I provide it for
    simple testing purposes.  Idiomatic @pipes@ style consumes the chunks
    immediately as they are generated instead of loading them all into memory.
-}
toLazyM :: (Monad m) => Producer BS.ByteString m () -> m BL.ByteString
toLazyM = liftM BL.fromChunks . P.toListM
{-# INLINABLE toLazyM #-}

-- | Reduce the stream of bytes using a strict left fold
fold
    :: Monad m
    => (x -> Word8 -> x) -> x -> (x -> r) -> Producer BS.ByteString m () -> m r
fold step begin done = P.fold (\x bs -> BS.foldl' step x bs) begin done
{-# INLINABLE fold #-}

-- | Retrieve the first 'Word8'
head :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
head = go
  where
    go p = do
        x <- next p
        case x of
            Left   ()      -> return Nothing
            Right (bs, p') ->
                if (BS.null bs)
                then go p'
                else return $ Just (BU.unsafeHead bs)
{-# INLINABLE head #-}

-- | Retrieve the last 'Word8'
last :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
last = go Nothing
  where
    go r p = do
        x <- next p
        case x of
            Left   ()      -> return r
            Right (bs, p') ->
                if (BS.null bs)
                then go r p'
                else go (Just $ BS.last bs) p'
                -- TODO: Change this to 'unsafeLast' when bytestring-0.10.2.0
                --       becomes more widespread
{-# INLINABLE last #-}

-- | Determine if the stream is empty
null :: (Monad m) => Producer BS.ByteString m () -> m Bool
null = P.all BS.null
{-# INLINABLE null #-}

-- | Count the number of bytes
length :: (Monad m, Num n) => Producer BS.ByteString m () -> m n
length = P.fold (\n bs -> n + fromIntegral (BS.length bs)) 0 id
{-# INLINABLE length #-}

-- | Fold that returns whether 'M.Any' received 'Word8's satisfy the predicate
any :: (Monad m) => (Word8 -> Bool) -> Producer BS.ByteString m () -> m Bool
any pred = P.any (BS.any pred)
{-# INLINABLE any #-}

-- | Fold that returns whether 'M.All' received 'Word8's satisfy the predicate
all :: (Monad m) => (Word8 -> Bool) -> Producer BS.ByteString m () -> m Bool
all pred = P.all (BS.all pred)
{-# INLINABLE all #-}

-- | Return the maximum 'Word8' within a byte stream
maximum :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
maximum = P.fold step Nothing id
  where
    step mw8 bs =
        if (BS.null bs)
        then mw8
        else case mw8 of
            Nothing -> Just (BS.maximum bs)
            Just w8 -> Just (max w8 (BS.maximum bs))
{-# INLINABLE maximum #-}

-- | Return the minimum 'Word8' within a byte stream
minimum :: (Monad m) => Producer BS.ByteString m () -> m (Maybe Word8)
minimum = P.fold step Nothing id
  where
    step mw8 bs =
        if (BS.null bs)
        then mw8
        else case mw8 of
            Nothing -> Just (BS.minimum bs)
            Just w8 -> Just (min w8 (BS.minimum bs))
{-# INLINABLE minimum #-}

-- | Determine whether any element in the byte stream matches the given 'Word8'
elem :: (Monad m) => Word8 -> Producer BS.ByteString m () -> m Bool
elem w8 = P.any (BS.elem w8)
{-# INLINABLE elem #-}

{-| Determine whether all elements in the byte stream do not match the given
    'Word8'
-}
notElem
    :: (Monad m) => Word8 -> Producer BS.ByteString m () -> m Bool
notElem w8 = P.all (BS.notElem w8)
{-# INLINABLE notElem #-}

-- | Find the first element in the stream that matches the predicate
find
    :: (Monad m)
    => (Word8 -> Bool) -> Producer BS.ByteString m () -> m (Maybe Word8)
find predicate p = head (p >-> filter predicate)
{-# INLINABLE find #-}

-- | Index into a byte stream
index
    :: (Monad m, Integral a)
    => a-> Producer BS.ByteString m () -> m (Maybe Word8)
index n p = head (p >-> drop n)
{-# INLINABLE index #-}

-- | Find the index of an element that matches the given 'Word8'
elemIndex
    :: (Monad m, Num n)
    => Word8 -> Producer BS.ByteString m () -> m (Maybe n)
elemIndex w8 = findIndex (w8 ==)
{-# INLINABLE elemIndex #-}

-- | Store the first index of an element that satisfies the predicate
findIndex
    :: (Monad m, Num n)
    => (Word8 -> Bool) -> Producer BS.ByteString m () -> m (Maybe n)
findIndex predicate p = P.head (p >-> findIndices predicate)
{-# INLINABLE findIndex #-}

-- | Store a tally of how many elements match the given 'Word8'
count :: (Monad m, Num n) => Word8 -> Producer BS.ByteString m () -> m n
count w8 p = P.fold (+) 0 id (p >-> P.map (fromIntegral . BS.count w8))
{-# INLINABLE count #-}

{-| Splits a 'Producer' after the given number of bytes

    @(splitAt n p)@ returns remainder of the bytes if @p@ had at least @n@ bytes
    or returns 'Left' if @p@ had an insufficient number of bytes.
-}
splitAt
    :: (Monad m, Integral n)
    => n
    -> Producer BS.ByteString m r
    -> Producer BS.ByteString m (Either r (Producer BS.ByteString m r))
splitAt = go
  where
    go 0 p = return (Right p)
    go n p = do
        x <- lift (next p)
        case x of
            Left   r       -> return (Left r)
            Right (bs, p') -> do
                let len = fromIntegral (BS.length bs)
                if (len <= n)
                    then do
                        yield bs
                        go (n - len) p'
                    else do
                        let (prefix, suffix) = BS.splitAt (fromIntegral n) bs
                        yield prefix
                        return $ Right (yield suffix >> p')
{-# INLINABLE splitAt #-}

-- | Split a byte stream into 'PP.FreeT'-delimited byte streams of fixed size
chunksOf
    :: (Monad m, Integral n)
    => n
    -> Producer BS.ByteString m r
    -> PP.FreeT (Producer BS.ByteString m) m r
chunksOf n = go
  where
    go p = PP.FreeT $ return $ PP.Free $ do
        x <- splitAt n p
        return $ case x of
            Left  r  -> return r
            Right p' -> go p'
{-# INLINABLE chunksOf #-}

-- | Intersperse a 'Word8' in between the bytes of the byte stream
intersperse
    :: (Monad m)
    => Word8 -> Producer BS.ByteString m r -> Producer BS.ByteString m r
intersperse w8 = go0
  where
    go0 p = do
        x <- lift (next p)
        case x of
            Left   r       -> return r
            Right (bs, p') -> do
                yield (BS.intersperse w8 bs)
                go1 p'
    go1 p = do
        x <- lift (next p)
        case x of
            Left   r       -> return r
            Right (bs, p') -> do
                yield (BS.singleton w8)
                yield (BS.intersperse w8 bs)
                go1 p'
{-# INLINABLE intersperse #-}

{-| 'intercalate' concatenates the 'FreeT'-delimited byte streams after
    interspersing a byte stream in between them
-}
intercalate
    :: (Monad m)
    => Producer BS.ByteString m ()
    -> PP.FreeT (Producer BS.ByteString m) m r
    -> Producer BS.ByteString m r
intercalate p0 = go0
  where
    go0 f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                f' <- p
                go1 f'
    go1 f = do
        x <- lift (PP.runFreeT f)
        case x of
            PP.Pure r -> return r
            PP.Free p -> do
                p0
                f' <- p
                go1 f'
{-# INLINABLE intercalate #-}

{-| Draw one non-empty 'BS.ByteString' from the underlying 'Producer', returning
    'Left' if the 'Producer' is empty
-}
draw
    :: (Monad m)
    => StateT (Producer BS.ByteString m r) m (Either r BS.ByteString)
draw = do
    x <- PP.draw
    case x of
        Left  r  -> return (Left r)
        Right bs ->
            if (BS.null bs)
            then draw
            else return (Right bs)
{-# INLINABLE draw #-}

{-| 'peek' checks the first non-empty 'BS.ByteString' in the stream, but uses
    'PP.unDraw' to push the element back so that it is available for the next
    'draw' command:

> peek = do
>     x <- draw
>     case x of
>         Left  _ -> return ()
>         Right a -> unDraw a
>     return x
-}
peek
    :: (Monad m)
    => StateT (Producer BS.ByteString m r) m (Either r BS.ByteString)
peek = do
    x <- draw
    case x of
        Left  _ -> return ()
        Right a -> PP.unDraw a
    return x
{-# INLINABLE peek #-}

{-| Check if the underlying 'Producer' has no more bytes

    Note that this will ignore empty 'BS.ByteString's, unlike 'PP.isEndOfInput'
    from @pipes-parse@.

> isEndOfInput = liftM isLeft peek
-}
isEndOfInput :: (Monad m) => StateT (Producer BS.ByteString m r) m Bool
isEndOfInput = do
    x <- peek
    return (case x of
        Left  _ -> True
        Right _ -> False )
{-# INLINABLE isEndOfInput #-}

{- $reexports
    @Pipes.Parse@ re-exports 'unDraw', 'input', and 'concat'
-}
