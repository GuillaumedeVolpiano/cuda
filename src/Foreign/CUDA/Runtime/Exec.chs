{-# LANGUAGE BangPatterns             #-}
{-# LANGUAGE CPP                      #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE GADTs                    #-}
{-# LANGUAGE TemplateHaskell          #-}
--------------------------------------------------------------------------------
-- |
-- Module    : Foreign.CUDA.Runtime.Exec
-- Copyright : [2009..2018] Trevor L. McDonell
-- License   : BSD
--
-- Kernel execution control for C-for-CUDA runtime interface
--
--------------------------------------------------------------------------------

module Foreign.CUDA.Runtime.Exec (

  -- * Kernel Execution
  Fun, FunAttributes(..), FunParam(..), CacheConfig(..),
  attributes, setCacheConfig, launchKernel,

) where

#include "cbits/stubs.h"
{# context lib="cudart" #}

-- Friends
import Foreign.CUDA.Runtime.Stream                      ( Stream(..), defaultStream )
import Foreign.CUDA.Runtime.Error
import Foreign.CUDA.Internal.C2HS

-- System
import Foreign
import Foreign.C
import Control.Monad
import Data.Maybe

#c
typedef struct cudaFuncAttributes cudaFuncAttributes;
#endc


--------------------------------------------------------------------------------
-- Data Types
--------------------------------------------------------------------------------

-- |
-- A @__global__@ device function.
--
-- Note that the use of a string naming a function was deprecated in CUDA 4.1
-- and removed in CUDA 5.0.
--
#if CUDART_VERSION >= 5000
type Fun = FunPtr ()
#else
type Fun = String
#endif


--
-- Function Attributes
--
{# pointer *cudaFuncAttributes as ^ foreign -> FunAttributes nocode #}

data FunAttributes = FunAttributes
  {
    constSizeBytes           :: !Int64,
    localSizeBytes           :: !Int64,
    sharedSizeBytes          :: !Int64,
    maxKernelThreadsPerBlock :: !Int,   -- ^ maximum block size that can be successively launched (based on register usage)
    numRegs                  :: !Int    -- ^ number of registers required for each thread
  }
  deriving (Show)

instance Storable FunAttributes where
  sizeOf _    = {# sizeof cudaFuncAttributes #}
  alignment _ = alignment (undefined :: Ptr ())

  poke _ _    = error "Can not poke Foreign.CUDA.Runtime.FunAttributes"
  peek p      = do
    cs <- cIntConv `fmap` {#get cudaFuncAttributes.constSizeBytes#} p
    ls <- cIntConv `fmap` {#get cudaFuncAttributes.localSizeBytes#} p
    ss <- cIntConv `fmap` {#get cudaFuncAttributes.sharedSizeBytes#} p
    tb <- cIntConv `fmap` {#get cudaFuncAttributes.maxThreadsPerBlock#} p
    nr <- cIntConv `fmap` {#get cudaFuncAttributes.numRegs#} p

    return FunAttributes
      {
        constSizeBytes           = cs,
        localSizeBytes           = ls,
        sharedSizeBytes          = ss,
        maxKernelThreadsPerBlock = tb,
        numRegs                  = nr
      }

#if CUDART_VERSION < 3000
data CacheConfig
#else
-- |
-- Cache configuration preference
--
{# enum cudaFuncCache as CacheConfig
    { }
    with prefix="cudaFuncCachePrefer" deriving (Eq, Show) #}
#endif

-- |
-- Kernel function parameters. Doubles will be converted to an internal float
-- representation on devices that do not support doubles natively.
--
data FunParam where
  IArg :: !Int             -> FunParam
  FArg :: !Float           -> FunParam
  DArg :: !Double          -> FunParam
  VArg :: Storable a => !a -> FunParam


--------------------------------------------------------------------------------
-- Execution Control
--------------------------------------------------------------------------------

-- |
-- Obtain the attributes of the named @__global__@ device function. This
-- itemises the requirements to successfully launch the given kernel.
--
{-# INLINEABLE attributes #-}
attributes :: Fun -> IO FunAttributes
attributes !fn = resultIfOk =<< cudaFuncGetAttributes fn

{-# INLINE cudaFuncGetAttributes #-}
{# fun unsafe cudaFuncGetAttributes
  { alloca-  `FunAttributes' peek*
  , withFun* `Fun'                 } -> `Status' cToEnum #}


-- |
-- On devices where the L1 cache and shared memory use the same hardware
-- resources, this sets the preferred cache configuration for the given device
-- function. This is only a preference; the driver is free to choose a different
-- configuration as required to execute the function.
--
-- Switching between configuration modes may insert a device-side
-- synchronisation point for streamed kernel launches
--
{-# INLINEABLE setCacheConfig #-}
setCacheConfig :: Fun -> CacheConfig -> IO ()
#if CUDART_VERSION < 3000
setCacheConfig _ _       = requireSDK 'setCacheConfig 3.0
#else
setCacheConfig !fn !pref = nothingIfOk =<< cudaFuncSetCacheConfig fn pref

{-# INLINE cudaFuncSetCacheConfig #-}
{# fun unsafe cudaFuncSetCacheConfig
  { withFun*  `Fun'
  , cFromEnum `CacheConfig' } -> `Status' cToEnum #}
#endif


-- |
-- Invoke a kernel on a @(gx * gy)@ grid of blocks, where each block contains
-- @(tx * ty * tz)@ threads and has access to a given number of bytes of shared
-- memory. The launch may also be associated with a specific 'Stream'.
--
{-# INLINEABLE launchKernel #-}
launchKernel
    :: Fun              -- ^ Device function symbol
    -> (Int,Int)        -- ^ grid dimensions
    -> (Int,Int,Int)    -- ^ thread block shape
    -> Int64            -- ^ shared memory per block (bytes)
    -> Maybe Stream     -- ^ (optional) execution stream
    -> [FunParam]
    -> IO ()
launchKernel !fn (!gx,!gy) (!bx,!by,!bz) !sm !mst !args
  = (=<<) nothingIfOk
  $ withMany withFP args
  $ \pa -> withArray pa
  $ \pp -> cudaLaunchKernelSimple fn gx gy 1 bx by bz pp sm (fromMaybe defaultStream mst)
  where
    withFP :: FunParam -> (Ptr FunParam -> IO b) -> IO b
    withFP p f = case p of
      IArg v -> with' v (f . castPtr)
      FArg v -> with' v (f . castPtr)
      DArg v -> with' v (f . castPtr)
      VArg v -> with' v (f . castPtr)

    with' :: Storable a => a -> (Ptr a -> IO b) -> IO b
    with' !val !f =
      allocaBytes (sizeOf val) $ \ptr -> do
        poke ptr val
        f ptr

{-# INLINE cudaLaunchKernelSimple #-}
{# fun unsafe cudaLaunchKernelSimple
  { withFun*  `Fun'
  ,           `Int', `Int', `Int'
  ,           `Int', `Int', `Int'
  , castPtr   `Ptr (Ptr FunParam)'
  ,           `Int64'
  , useStream `Stream'
  }
  -> `Status' cToEnum #}

--------------------------------------------------------------------------------
-- Internals
--------------------------------------------------------------------------------

-- CUDA 5.0 changed the type of a kernel function from char* to void*
--
#if CUDART_VERSION >= 5000
withFun :: Fun -> (Ptr a -> IO b) -> IO b
withFun fn action = action (castFunPtrToPtr fn)
#else
withFun :: Fun -> (Ptr CChar -> IO a) -> IO a
withFun           = withCString
#endif

