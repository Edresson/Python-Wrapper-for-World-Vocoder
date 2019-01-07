from __future__ import division
import cython

import numpy as np
cimport numpy as np
np.import_array()


cdef extern from "world/synthesis.h":
    void Synthesize(const double *f0,
        int f0_length, const double * const *spectrogram,
        const double * const *aperiodicity,
        int fft_size, double frame_period,
        int fs, int y_length, double *y) except +


cdef extern from "world/cheaptrick.h":
    ctypedef struct CheapTrickOption:
        double q1
        double f0_floor

    int GetFFTSizeForCheapTrick(int fs, const CheapTrickOption *option) except +
    void InitializeCheapTrickOption(CheapTrickOption *option) except +
    void CheapTrick(const double *x, int x_length, int fs, const double *temporal_positions,
        const double *f0, int f0_length, const CheapTrickOption *option,
        double **spectrogram) except +


cdef extern from "world/dio.h":
    ctypedef struct DioOption:
        double f0_floor
        double f0_ceil
        double channels_in_octave
        double frame_period
        int speed
        double allowed_range

    void InitializeDioOption(DioOption *option) except +
    int GetSamplesForDIO(int fs, int x_length, double frame_period)
    void Dio(const double *x, int x_length, int fs, const DioOption *option,
        double *temporal_positions, double *f0) except +


cdef extern from "world/d4c.h":
    ctypedef struct D4COption:
        double dummy

    void InitializeD4COption(D4COption *option) except +
    void D4C(const double *x, int x_length, int fs, const double *temporal_positions,
        const double *f0, int f0_length, int fft_size, const D4COption *option,
        double **aperiodicity) except +
    void D4C_coarse(const double *x, int x_length, int fs, const double *temporal_positions,
        const double *f0, int f0_length, int fft_size, const D4COption *option,
        double **aperiodicity) except +


cdef extern from "world/stonemask.h":
    void StoneMask(const double *x, int x_length, int fs,
        const double *temporal_positions, const double *f0, int f0_length,
        double *refined_f0) except +


default_frame_period = 8.0
default_f0_floor = 71.0
default_f0_ceil = 800.0


def dio(np.ndarray[double, ndim=1, mode="c"] x not None, int fs,
        f0_floor=default_f0_floor, f0_ceil=default_f0_ceil,
        channels_in_octave=2.0, frame_period=default_frame_period,
        speed=1, allowed_range=0.1):
    """DIO F0 extraction algorithm.

    Parameters
    ----------
    x : ndarray
        Input waveform signal.
    fs : int
        Sample rate of input signal in Hz.
    f0_floor : float
        Lower F0 limit in Hz.
        Default: 71.0
    f0_ceil : float
        Upper F0 limit in Hz.
        Default: 800.0
    channels_in_octave : float
        Resolution of multiband processing; normally shouldn't be changed.
        Default: 2.0
    frame_period : float
        Period between consecutive frames in milliseconds.
        Default: 5.0
    speed : int
        The F0 estimator may downsample the input signal using this integer factor
        (range [1;12]). The algorithm will then operate on a signal at fs/speed Hz
        to reduce computational complexity, but high values may negatively impact
        accuracy.
        Default: 1 (no downsampling)
    allowed_range : float
        Threshold for voiced/unvoiced decision. Can be any value >= 0, but 0.02 to 0.2
        is a reasonable range. Lower values will cause more frames to be considered
        unvoiced (in the extreme case of `threshold=0`, almost all frames will be unvoiced).
        Default: 0.1

    Returns
    -------
    f0 : ndarray
        Estimated F0 contour.
    temporal_positions : ndarray
        Temporal position of each frame.
    """
    cdef int x_length = <int>len(x)
    cdef DioOption option
    InitializeDioOption(&option)
    option.channels_in_octave = channels_in_octave
    option.f0_floor = f0_floor
    option.f0_ceil = f0_ceil
    option.frame_period = frame_period
    option.speed = speed
    f0_length = GetSamplesForDIO(fs, x_length, option.frame_period)
    cdef np.ndarray[double, ndim=1, mode="c"] f0 = \
        np.zeros(f0_length, dtype=np.dtype('float64'))
    cdef np.ndarray[double, ndim=1, mode="c"] temporal_positions = \
        np.zeros(f0_length, dtype=np.dtype('float64'))
    Dio(&x[0], x_length, fs, &option, &temporal_positions[0], &f0[0])
    return f0, temporal_positions


def stonemask(np.ndarray[double, ndim=1, mode="c"] x not None,
              np.ndarray[double, ndim=1, mode="c"] f0 not None,
              np.ndarray[double, ndim=1, mode="c"] temporal_positions not None,
              int fs):
    """StoneMask F0 refinement algorithm.

    Parameters
    ----------
    x : ndarray
        Input waveform signal.
    f0 : ndarray
        Input F0 contour.
    temporal_positions : ndarray
        Temporal positions of each frame.
    fs : int
        Sample rate of input signal in Hz.

    Returns
    -------
    refined_f0 : ndarray
        Refined F0 contour.
    """
    cdef int x_length = <int>len(x)
    cdef int f0_length = <int>len(f0)
    cdef np.ndarray[double, ndim=1, mode="c"] refined_f0 = \
        np.zeros(f0_length, dtype=np.dtype('float64'))
    StoneMask(&x[0], x_length, fs, &temporal_positions[0],
        &f0[0], f0_length, &refined_f0[0])
    return refined_f0


def get_cheaptrick_fft_size(fs, f0_floor=default_f0_floor):
    """Calculate suitable FFT size for CheapTrick given F0 floor.

    Parameters
    ----------
    fs : int
        Sample rate of input signal in Hz.
    f0_floor : float
        Lower F0 limit in Hz. The required FFT size is a direct
        consequence of the F0 floor used.
        Default: 71.0

    Returns
    -------
    fft_size : int
        Resulting FFT size.
    """
    cdef CheapTrickOption option
    option.f0_floor = f0_floor
    cdef int fft_size = GetFFTSizeForCheapTrick(fs, &option)
    return fft_size


def cheaptrick(np.ndarray[double, ndim=1, mode="c"] x not None,
               np.ndarray[double, ndim=1, mode="c"] f0 not None,
               np.ndarray[double, ndim=1, mode="c"] temporal_positions not None,
               int fs,
               q1=-0.15, f0_floor=default_f0_floor, fft_size=None):
    """CheapTrick harmonic spectral envelope estimation algorithm.

    Parameters
    ----------
    x : ndarray
        Input waveform signal.
    f0 : ndarray
        Input F0 contour.
    temporal_positions : ndarray
        Temporal positions of each frame.
    fs : int
        Sample rate of input signal in Hz.
    q1 : float
        Spectral recovery parameter.
        Default: -0.15 (this value was tuned and normally does not need adjustment)
    f0_floor : float, None
        Lower F0 limit in Hz. Not used in case `fft_size` is specified.
        Default: 71.0
    fft_size : int, None
        FFT size to be used. When `None` (default) is used, the FFT size is computed
        automatically as a function of the given input sample rate and F0 floor.
        When `fft_size` is specified, the given `f0_floor` parameter is ignored.
        Default: None

    Returns
    -------
    spectrogram : ndarray
        Spectral envelope (squared magnitude).
    """
    cdef CheapTrickOption option
    InitializeCheapTrickOption(&option)
    option.q1 = q1
    option.f0_floor = f0_floor  # CheapTrickOption.f0_floor is only used in GetFFTSizeForCheapTrick()
    if fft_size is None:
        fft_size = GetFFTSizeForCheapTrick(fs, &option)
        # the f0_floor used by CheapTrick() will be re-compute from this given fft_size
    cdef int x_length = <int>len(x)
    cdef int f0_length = <int>len(f0)

    cdef double[:, ::1] spectrogram = np.zeros((f0_length, fft_size//2 + 1),
                                               dtype=np.dtype('float64'))
    cdef np.intp_t[:] tmp = np.zeros(f0_length, dtype=np.intp)
    cdef double **cpp_spectrogram = <double**> (<void*> &tmp[0])
    cdef np.intp_t i
    for i in range(f0_length):
        cpp_spectrogram[i] = &spectrogram[i, 0]

    CheapTrick(&x[0], x_length, fs, &temporal_positions[0],
        &f0[0], f0_length, &option, cpp_spectrogram)
    return np.array(spectrogram, dtype=np.float64)


def d4c(np.ndarray[double, ndim=1, mode="c"] x not None,
        np.ndarray[double, ndim=1, mode="c"] f0 not None,
        np.ndarray[double, ndim=1, mode="c"] temporal_positions not None,
        int fs,
        order=5, fft_size=None):
    """D4C aperiodicity estimation algorithm.

    Parameters
    ----------
    x : ndarray
        Input waveform signal.
    f0 : ndarray
        Input F0 contour.
    temporal_positions : ndarray
        Temporal positions of each frame.
    fs : int
        Sample rate of input signal in Hz.
    q1 : float
        Spectral recovery parameter.
        Default: -0.15 (this value was tuned and normally does not need adjustment)
    threshold : float
        Threshold for aperiodicity-based voiced/unvoiced decision, in range 0 to 1.
        If a value of 0 is used, voiced frames will be kept voiced. If a value > 0 is
        used some voiced frames can be considered unvoiced by setting their aperiodicity
        to 1 (thus synthesizing them with white noise). Using `threshold=0` will result
        in the behavior of older versions of D4C. The current default of 0.85 is meant
        to be used in combination with the Harvest F0 estimator, which was designed to have
        a high voiced/unvoiced threshold (i.e. most frames will be considered voiced).
        Default: 0.85
    fft_size : int, None
        FFT size to be used. When `None` (default) is used, the FFT size is computed
        automatically as a function of the given input sample rate and the default F0 floor.
        When `fft_size` is specified, it should match the FFT size used to compute
        the spectral envelope (i.e. `fft_size=2*(sp.shape[1] - 1)`) in order to get the
        desired results when resynthesizing.
        Default: None

    Returns
    -------
    aperiodicity : ndarray
        Aperiodicity (envelope, linear magnitude relative to spectral envelope).
    """
    cdef int x_length = <int>len(x)
    cdef int f0_length = <int>len(f0)
    cdef int fft_size0
    if fft_size is None:
        fft_size0 = get_cheaptrick_fft_size(fs, default_f0_floor)
    else:
        fft_size0 = fft_size

    cdef D4COption option
    InitializeD4COption(&option)

    cdef double[:, ::1] aperiodicity = np.zeros((f0_length, order),
                                                dtype=np.dtype('float64'))
    cdef np.intp_t[:] tmp = np.zeros(f0_length, dtype=np.intp)
    cdef double **cpp_aperiodicity = <double**> (<void*> &tmp[0])
    cdef np.intp_t i
    for i in range(f0_length):
        cpp_aperiodicity[i] = &aperiodicity[i, 0]

    D4C_coarse(&x[0], x_length, fs, &temporal_positions[0],
        &f0[0], f0_length, fft_size0, &option,
        cpp_aperiodicity)
    return np.array(aperiodicity, dtype=np.float64)


def synthesize(np.ndarray[double, ndim=1, mode="c"] f0 not None,
               np.ndarray[double, ndim=2, mode="c"] spectrogram not None,
               np.ndarray[double, ndim=2, mode="c"] aperiodicity not None,
               int fs,
               double frame_period=default_frame_period):
    """WORLD synthesis from parametric representation.

    Parameters
    ----------
    f0 : ndarray
        Input F0 contour.
    spectrogram : ndarray
        Spectral envelope.
    aperiodicity : ndarray
        Aperodicity envelope.
    fs : int
        Sample rate of input signal in Hz.
    frame_period : float
        Period between consecutive frames in milliseconds.
        Default: 5.0

    Returns
    -------
    y : ndarray
        Output waveform signal.
    """
    if (f0.shape[0] != spectrogram.shape[0] or
        f0.shape[0] != aperiodicity.shape[0]):
        raise ValueError('Mismatched number of frames between F0 ({:d}), '
                         'spectrogram ({:d}) and aperiodicty ({:d})'
                         .format(f0.shape[0], spectrogram.shape[0],
                                 aperiodicity.shape[0]))

    cdef int f0_length = <int>len(f0)
    y_length = int(f0_length * frame_period * fs / 1000)
    cdef int fft_size = (<int>spectrogram.shape[1] - 1)*2
    cdef np.ndarray[double, ndim=1, mode="c"] y = \
        np.zeros(y_length, dtype=np.dtype('float64'))

    cdef double[:, ::1] spectrogram0 = spectrogram
    cdef double[:, ::1] aperiodicity0 = aperiodicity
    cdef np.intp_t[:] tmp = np.zeros(f0_length, dtype=np.intp)
    cdef np.intp_t[:] tmp2 = np.zeros(f0_length, dtype=np.intp)
    cdef double **cpp_spectrogram = <double**> (<void*> &tmp[0])
    cdef double **cpp_aperiodicity = <double**> (<void*> &tmp2[0])
    cdef np.intp_t i
    for i in range(f0_length):
        cpp_spectrogram[i] = &spectrogram0[i, 0]
        cpp_aperiodicity[i] = &aperiodicity0[i, 0]

    Synthesize(&f0[0], f0_length, cpp_spectrogram,
        cpp_aperiodicity, fft_size, frame_period, fs, y_length, &y[0])
    return y

def wav2world(x, fs, fft_size=None, frame_period=default_frame_period, ap_depth=5):
    """Convenience function to do all WORLD analysis steps in a single call.

    In this case only `frame_period` can be configured and other parameters
    are fixed to their defaults. Likewise, F0 estimation is fixed to
    DIO plus StoneMask refinement.

    Parameters
    ----------
    x : ndarray
        Input waveform signal.
    fs : int
        Sample rate of input signal in Hz.
    frame_period : float
        Period between consecutive frames in milliseconds.
        Default: 5.0
    fft_size : int
        Length of Fast Fourier Transform (in number of samples)
        The resulting dimension of `ap` adn `sp` will be `fft_size` // 2 + 1

    Returns
    -------
    f0 : ndarray
        F0 contour.
    sp : ndarray
        Spectral envelope.
    ap : ndarray
        Aperiodicity.
    """
    _f0, t = dio(x, fs, frame_period=frame_period)
    f0 = stonemask(x, _f0, t, fs)
    sp = cheaptrick(x, f0, t, fs, fft_size=fft_size)
    ap = d4c(x, f0, t, fs, order=ap_depth, fft_size=fft_size)
    return f0, sp, ap
