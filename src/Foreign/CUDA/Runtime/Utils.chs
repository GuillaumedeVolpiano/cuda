{-# LANGUAGE ForeignFunctionInterface #-}
--------------------------------------------------------------------------------
-- |
-- Module    : Foreign.CUDA.Runtime.Utils
-- Copyright : [2009..2020] Trevor L. McDonell
-- License   : BSD
--
-- Utility functions
--
--------------------------------------------------------------------------------

module Foreign.CUDA.Runtime.Utils (

  runtimeVersion,
  driverVersion,
  libraryVersion,

) where

#include "cbits/stubs.h"
{# context lib="cudart" #}

-- Friends
import Foreign.CUDA.Runtime.Error
import Foreign.CUDA.Internal.C2HS

-- System
import Foreign
import Foreign.C


-- |
-- Return the version number of the installed CUDA driver
--
{-# INLINEABLE runtimeVersion #-}
runtimeVersion :: IO Int
runtimeVersion =  resultIfOk =<< cudaRuntimeGetVersion

{-# INLINE cudaRuntimeGetVersion #-}
{# fun unsafe cudaRuntimeGetVersion
  { alloca- `Int' peekIntConv* } -> `Status' cToEnum #}


-- |
-- Return the version number of the installed CUDA runtime
--
{-# INLINEABLE driverVersion #-}
driverVersion :: IO Int
driverVersion =  resultIfOk =<< cudaDriverGetVersion

{-# INLINE cudaDriverGetVersion #-}
{# fun unsafe cudaDriverGetVersion
  { alloca- `Int' peekIntConv* } -> `Status' cToEnum #}


-- |
-- Return the version number of the CUDA library (API) that this package was
-- compiled against.
--
{-# INLINEABLE libraryVersion #-}
libraryVersion :: Int
libraryVersion = {#const CUDART_VERSION #}

