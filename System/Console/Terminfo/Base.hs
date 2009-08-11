-- |
-- Maintainer  : judah.jacobson@gmail.com
-- Stability   : experimental
-- Portability : portable (FFI)
--
-- This module provides a low-level interface to the C functions of the 
-- terminfo library. 
-- 
-- NOTE: Since this library is built on top of the curses interface, it is not thread-safe.

module System.Console.Terminfo.Base(
                            -- *  Initialization
                            Terminal(),
                            setupTerm,
                            setupTermFromEnv,
                            SetupTermError,
                            -- * Capabilities
                            Capability,
                            getCapability,
                            tiGetFlag,
                            tiGuardFlag,
                            tiGetNum,
                            tiGetStr,
                            -- * Output
                            -- $outputdoc
                            tiGetOutput1,
                            OutputCap,
                            TermStr,
                            -- ** TermOutput
                            TermOutput(),
                            runTermOutput,
                            hRunTermOutput,
                            termText,
                            tiGetOutput,
                            LinesAffected,
                            -- ** Monoid functions
                            Monoid(..),
                            (<#>),
                            ) where


import Control.Monad
import Data.Monoid
import Foreign.C
import Foreign.ForeignPtr
import Foreign.Ptr
import Foreign.Marshal
import Foreign.Storable (peek,poke)
import System.Environment (getEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.IO
import Control.Exception.Extensible
import Data.Typeable


data TERMINAL
newtype Terminal = Terminal (ForeignPtr TERMINAL)

foreign import ccall "&" cur_term :: Ptr (Ptr TERMINAL)
foreign import ccall set_curterm :: Ptr TERMINAL -> IO (Ptr TERMINAL)
foreign import ccall "&" del_curterm :: FunPtr (Ptr TERMINAL -> IO ())

foreign import ccall setupterm :: CString -> CInt -> Ptr CInt -> IO ()

-- | Initialize the terminfo library to the given terminal entry.
-- 
-- Throws a 'SetupTermError' if the terminfo database could not be read.
setupTerm :: String -> IO Terminal
setupTerm term = bracket (peek cur_term) (poke cur_term) $ \_ -> 
    withCString term $ \c_term ->
    with 0 $ \ret_ptr -> do
        -- NOTE: I believe that for the way we use terminfo
        -- (i.e. custom output function)
        -- this parameter does not affect anything.
        let stdOutput = 1
        {-- Force ncurses to return a new struct rather than
        a copy of the current one (which it would do if the
        terminal names are the same).  This prevents problems
        when calling del_term on a struct shared by more than one
        Terminal. --}
        poke cur_term nullPtr
        -- Call setupterm and check the return value.
        setupterm c_term stdOutput ret_ptr
        ret <- peek ret_ptr
        if (ret /=1)
            then throwIO $ SetupTermError
                $ "Couldn't look up terminfo entry " ++ show term
            else do
                cterm <- peek cur_term
                fmap Terminal $ newForeignPtr del_curterm cterm

data SetupTermError = SetupTermError String
                        deriving Typeable

instance Show SetupTermError where
    show (SetupTermError str) = "setupTerm: " ++ str

instance Exception SetupTermError where

-- | Initialize the terminfo library, using the @TERM@ environmental variable.
-- If @TERM@ is not set, we use the generic, minimal entry @dumb@.
-- 
-- Throws a 'SetupTermError' if the terminfo database could not be read.
setupTermFromEnv :: IO Terminal
setupTermFromEnv = do
    env_term <- handle handleBadEnv $ getEnv "TERM" 
    let term = if null env_term then "dumb" else env_term
    setupTerm term
  where
    handleBadEnv :: IOException -> IO String
    handleBadEnv _ = return ""

-- TODO: this isn't really thread-safe...
withCurTerm :: Terminal -> IO a -> IO a
withCurTerm (Terminal term) f = withForeignPtr term $ \cterm -> do
        old_term <- peek cur_term
        if old_term /= cterm
            then do
                    _ <- set_curterm cterm
                    x <- f
                    _ <- set_curterm old_term
                    return x
            else f


----------------------

-- Note I'm relying on this working even for strings with unset parameters.
strHasPadding :: String -> Bool
strHasPadding [] = False
strHasPadding ('$':'<':_) = True
strHasPadding (_:cs) = strHasPadding cs

-- | An action which sends output to the terminal.  That output may mix plain text with control
-- characters and escape sequences, along with delays (called \"padding\") required by some older
-- terminals.

-- We structure this similarly to ShowS, so that appends don't cause space leaks.
newtype TermOutput = TermOutput ([TermOutputType] -> [TermOutputType])

data TermOutputType = TOCmd LinesAffected String
                    | TOStr String

instance Monoid TermOutput where
    mempty = TermOutput id
    TermOutput xs `mappend` TermOutput ys = TermOutput (xs . ys)

termText :: String -> TermOutput 
termText str = TermOutput (TOStr str :)

-- | Write the terminal output to the standard output device.
runTermOutput :: Terminal -> TermOutput -> IO ()
runTermOutput = hRunTermOutput stdout

-- | Write the terminal output to the terminal or file managed by the given
-- 'Handle'.
hRunTermOutput :: Handle -> Terminal -> TermOutput -> IO ()
hRunTermOutput h term (TermOutput to) = do
    putc_ptr <- mkCallback putc
    withCurTerm term $ mapM_ (writeToTerm putc_ptr h) (to [])
    freeHaskellFunPtr putc_ptr
  where
    putc c = let c' = toEnum $ fromEnum c
             in hPutChar h c' >> hFlush h >> return c

writeToTerm :: FunPtr CharOutput -> Handle -> TermOutputType -> IO ()
writeToTerm putc _ (TOCmd numLines s) = tPuts s numLines putc
writeToTerm _ h (TOStr s) = hPutStr h s >> hFlush h

infixl 2 <#>

-- | An operator version of 'mappend'.
(<#>) :: Monoid m => m -> m -> m
(<#>) = mappend
---------------------------------

-- | A feature or operation which a 'Terminal' may define.
newtype Capability a = Capability (IO (Maybe a))

getCapability :: Terminal -> Capability a -> Maybe a
getCapability term (Capability f) = unsafePerformIO $ withCurTerm term f

-- Note that the instances for Capability of Functor, Monad and MonadPlus 
-- use the corresponding instances for Maybe.
instance Functor Capability where
    fmap f (Capability g) = Capability (fmap (fmap f) g) 

instance Monad Capability where
    return = Capability . return . Just
    Capability f >>= g = Capability $ do
        mx <- f
        case mx of
            Nothing -> return Nothing
            Just x -> let Capability g' = g x in g'

instance MonadPlus Capability where
    mzero = Capability (return Nothing)
    Capability f `mplus` Capability g = Capability $ do
        mx <- f
        case mx of
            Nothing -> g
            _ -> return mx

foreign import ccall tigetnum :: CString -> IO CInt

-- | Look up a numeric capability in the terminfo database.
tiGetNum :: String -> Capability Int 
tiGetNum cap = Capability $ do
                n <- fmap fromEnum (withCString cap tigetnum)
                if n >= 0
                    then return (Just n)
                    else return Nothing

foreign import ccall tigetflag :: CString -> IO CInt
-- | Look up a boolean capability in the terminfo database.  
-- 
-- Unlike 'tiGuardFlag', this capability never fails; it returns 'False' if the
-- capability is absent or set to false, and returns 'True' otherwise.  
-- 
tiGetFlag :: String -> Capability Bool
tiGetFlag cap = Capability $ fmap (Just . (>0)) $
                        withCString cap tigetflag
                
-- | Look up a boolean capability in the terminfo database, and fail if
-- it\'s not defined.
tiGuardFlag :: String -> Capability ()
tiGuardFlag cap = tiGetFlag cap >>= guard
                
foreign import ccall tigetstr :: CString -> IO CString

{-# DEPRECATED tiGetStr "use tiGetOutput instead." #-} 
-- | Look up a string capability in the terminfo database.  NOTE: This function is deprecated; use
-- 'tiGetOutput1' instead.
tiGetStr :: String -> Capability String
tiGetStr cap = Capability $ do
                result <- withCString cap tigetstr 
                if result == nullPtr || result == neg1Ptr
                    then return Nothing
                    else fmap Just (peekCString result)
    where
        -- hack; tigetstr sometimes returns (-1)
        neg1Ptr = nullPtr `plusPtr` (-1)


---------------


                    
foreign import ccall tparm ::
    CString -> CLong -> CLong -> CLong -> CLong -> CLong -> CLong 
    -> CLong -> CLong -> CLong -- p1,...,p9
    -> IO CString

-- Note: I may want to cut out the middleman and pipe tGoto/tGetStr together
-- with tput without a String marshall in the middle.
-- directly without 

tParm :: String -> [Int] -> IO String
tParm cap ps = tparm' (map toEnum ps ++ repeat 0)
    where tparm' (p1:p2:p3:p4:p5:p6:p7:p8:p9:_)
            = withCString cap $ \c_cap -> do
                result <- tparm c_cap p1 p2 p3 p4 p5 p6 p7 p8 p9
                peekCString result
          tparm' _ = fail "tParm: List too short"

-- | Look up an output capability in the terminfo database.  
tiGetOutput :: String -> Capability ([Int] -> LinesAffected -> TermOutput)
tiGetOutput cap = do
    str <- tiGetStr cap
    -- TODO: make sure to put withCurTerm in here somewhere...
    -- check this doesn't cause slowdown, maybe just accesses a ptr
    -- a bunch of times which should be OK?
    return $ \ps la -> fromStr la $ unsafePerformIO $ tParm str ps

fromStr :: LinesAffected -> String -> TermOutput
fromStr la s = TermOutput (TOCmd la s :)

type CharOutput = CInt -> IO CInt

foreign import ccall "wrapper" mkCallback :: CharOutput -> IO (FunPtr CharOutput)

foreign import ccall tputs :: CString -> CInt -> FunPtr CharOutput -> IO ()

-- | A parameter to specify the number of lines affected.  Some capabilities
-- (e.g., @clear@ and @dch1@) use
-- this parameter on some terminals to compute variable-length padding.
type LinesAffected = Int

-- | Output a string capability.  Applys padding information to the string if
-- necessary.
tPuts :: String -> LinesAffected -> FunPtr CharOutput -> IO ()
tPuts s n putc = withCString s $ \c_str -> tputs c_str (toEnum n) putc


-- | Look up an output capability which takes a fixed number of parameters
-- (for example, @Int -> Int -> TermOutput@).
-- 
-- For capabilities which may contain variable-length
-- padding, use 'tiGetOutput' instead.
tiGetOutput1 :: forall f . OutputCap f => String -> Capability f
tiGetOutput1 str = do
    cap <- tiGetStr str
    guard (hasOkPadding (undefined :: f) cap)
    -- TODO: withCurTerm somewhere
    let listCap xs = unsafePerformIO $ tParm cap xs
    return $ outputCap listCap []


-- OK, this is the structure that I want:
class OutputCap f where
    hasOkPadding :: f -> String -> Bool
    outputCap :: ([Int] -> String) -> [Int] -> f

instance OutputCap [Char] where
    hasOkPadding _ = not . strHasPadding 
    outputCap f xs = f (reverse xs)

instance OutputCap TermOutput where
    hasOkPadding _ = const True
    outputCap f xs = fromStr 1 $ f $ reverse xs

instance (Enum p, OutputCap f) => OutputCap (p -> f) where
    outputCap f xs = \x -> outputCap f (fromEnum x:xs)
    hasOkPadding _ = hasOkPadding (undefined :: f)


{- $outputdoc
Terminfo contains many string capabilities for special effects.
For example, the @cuu1@ capability moves the cursor up one line; on ANSI terminals
this is accomplished by printing the control sequence @\"\\ESC[A\"@.
However, some older terminals also require \"padding\", or short pauses, after certain commands.
For example, when @TERM=vt100@ the @cuu1@ capability is @\"\\ESC[A$\<2\>\"@, which instructs terminfo
to pause for two milliseconds after outputting the control sequence.

The 'TermOutput' monoid abstracts away all padding and control
sequence output.  Unfortunately, that datatype is difficult to integrate into existing 'String'-based APIs
such as pretty-printers.  Thus, as a workaround, 'tiGetOutput1' also lets us access the control sequences as 'String's.  The one caveat is that it will not allow you to access padded control sequences as Strings.  For example:

   > > t <- setupTerm "vt100"
   > > isJust (getCapability t (tiGetOutput1 "cuu1") :: Maybe String)
   > False
   > > isJust (getCapability t (tiGetOutput1 "cuu1") :: Maybe TermOutput)
   > True

'String' capabilities will work with software-based terminal types such as @xterm@ and @linux@.
However, you should use 'TermOutput' if compatibility with older terminals is important.
Additionally, the @visualBell@ capability which flashes the screen usually produces its effect with a padding directive, so it will only work with 'TermOutput'.

-}


class (Monoid s, OutputCap s) => TermStr s

instance TermStr [Char]
instance TermStr TermOutput
