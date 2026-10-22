// SPDX-License-Identifier: GPL-3.0-only
using System;
using System.Collections.Generic;
using System.IO;
using ZXing;
using ZXing.Common;
using ZXing.Multi.QrCode.Internal;
using ZXing.QrCode.Internal;
#if !REVERSE_QR_PORTABLE
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
#endif

namespace DeskBridge.Reverse
{
    // A selected file is decoded locally. Its text is data, never a shell command or
    // URL to open; the caller must pass it through ConnectionPolicy before connecting.
    internal static class ReverseQrReader
    {
        internal const int MaxFileBytes = 8 * 1024 * 1024;
        internal const int MaxPixels = 16000000;
        internal const int MaxDimension = 16384;
        internal const int MaxDecodeDimension = 2048;
        private const int MaxFinderPatterns = 24;
        private const int MaxDetectorCandidates = 16;

#if !REVERSE_QR_PORTABLE
        internal static string Read(string path)
        {
            if (String.IsNullOrWhiteSpace(path)) throw Invalid("Choose a local QR image.");
            string full = Path.GetFullPath(path);
            if (full.StartsWith("\\\\", StringComparison.Ordinal) || full.IndexOf(':', 2) >= 0)
                throw Invalid("Copy the QR image to a local folder before opening it.");
            DriveType drive = new DriveInfo(Path.GetPathRoot(full)).DriveType;
            if (drive != DriveType.Fixed && drive != DriveType.Removable && drive != DriveType.CDRom)
                throw Invalid("Copy the QR image to a local folder before opening it.");
            // Refuse reparse points, including parent folders, so selecting an image
            // cannot silently follow a cloud/network redirect or a device path.
            for (string item = full; !String.IsNullOrEmpty(item); item = Path.GetDirectoryName(item))
                if ((File.GetAttributes(item) & FileAttributes.ReparsePoint) != 0)
                    throw Invalid("Copy the QR image out of a linked or cloud-only folder first.");
            byte[] encoded;
            using (FileStream file = new FileStream(full, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                ValidateFileLength(file.Length);
                encoded = new byte[(int)file.Length];
                int position = 0;
                while (position < encoded.Length)
                {
                    int count = file.Read(encoded, position, encoded.Length - position);
                    if (count == 0) throw Invalid("The QR image could not be read completely.");
                    position += count;
                }
                if (file.ReadByte() != -1) throw Invalid("The QR image changed while it was being read.");
            }
            ImageHeader header = InspectImage(encoded);
            try
            {
                using (MemoryStream stream = new MemoryStream(encoded, false))
                using (Image image = Image.FromStream(stream, false, true))
                {
                    ValidateDimensions(image.Width, image.Height);
                    if (image.Width != header.Width || image.Height != header.Height)
                        throw Invalid("The QR image has inconsistent dimensions.");
                    double scale = Math.Min(1.0, (double)MaxDecodeDimension / Math.Max(image.Width, image.Height));
                    int width = Math.Max(1, (int)Math.Floor(image.Width * scale));
                    int height = Math.Max(1, (int)Math.Floor(image.Height * scale));
                    using (Bitmap bitmap = new Bitmap(width, height, PixelFormat.Format24bppRgb))
                    {
                        using (Graphics graphics = Graphics.FromImage(bitmap))
                        {
                            graphics.Clear(Color.White);
                            graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
                            graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
                            graphics.DrawImage(image, new Rectangle(0, 0, width, height), 0, 0,
                                image.Width, image.Height, GraphicsUnit.Pixel);
                        }
                        byte[] luminance = new byte[checked(width * height)];
                        BitmapData data = bitmap.LockBits(new Rectangle(0, 0, width, height),
                            ImageLockMode.ReadOnly, PixelFormat.Format24bppRgb);
                        try
                        {
                            byte[] row = new byte[checked(width * 3)];
                            for (int y = 0; y < height; y++)
                            {
                                Marshal.Copy(IntPtr.Add(data.Scan0, checked(y * data.Stride)), row, 0, row.Length);
                                for (int x = 0; x < width; x++)
                                {
                                    int offset = x * 3;
                                    luminance[y * width + x] = (byte)((row[offset + 2] * 306 + row[offset + 1] * 601 + row[offset] * 117 + 512) >> 10);
                                }
                            }
                        }
                        finally { bitmap.UnlockBits(data); }
                        int orientedWidth, orientedHeight;
                        luminance = Orient(luminance, width, height, header.Orientation, out orientedWidth, out orientedHeight);
                        return ReadLuminance(luminance, orientedWidth, orientedHeight);
                    }
                }
            }
            catch (ArgumentException) { throw Invalid("The image is damaged or is not a supported PNG, JPEG or BMP file."); }
            catch (ExternalException) { throw Invalid("The image could not be decoded. Save it as PNG and try again."); }
        }
#endif

        internal static void ValidateFileLength(long length)
        {
            if (length <= 0 || length > MaxFileBytes) throw Invalid("Choose a QR image no larger than 8 MiB.");
        }

        internal static void ValidateDimensions(int width, int height)
        {
            if (width <= 0 || height <= 0 || width > MaxDimension || height > MaxDimension || (long)width * height > MaxPixels)
                throw Invalid("Choose a QR image no larger than 16 megapixels and 16384 pixels per side.");
        }

        internal sealed class ImageHeader
        {
            internal int Width, Height, Orientation = 1;
        }

        // Parse dimensions before invoking an operating-system image codec. Formats
        // without a bounded, recognised header (GIF/TIFF/WebP/SVG/PDF) are refused.
        internal static ImageHeader InspectImage(byte[] bytes)
        {
            if (bytes == null) throw Invalid("Choose a PNG, JPEG or BMP QR image.");
            ValidateFileLength(bytes.Length);
            ImageHeader result = new ImageHeader();
            if (bytes.Length >= 33 && bytes[0] == 137 && bytes[1] == 80 && bytes[2] == 78 && bytes[3] == 71 &&
                bytes[4] == 13 && bytes[5] == 10 && bytes[6] == 26 && bytes[7] == 10)
            {
                if (Big32(bytes, 8) != 13 || !Kind(bytes, 12, "IHDR")) throw Invalid("The PNG header is invalid.");
                result.Width = Positive(Big32(bytes, 16)); result.Height = Positive(Big32(bytes, 20));
                int offset = 8; bool ended = false;
                while (offset <= bytes.Length - 12)
                {
                    uint size = Big32(bytes, offset);
                    if (size > (uint)(bytes.Length - offset - 12)) throw Invalid("The PNG image is truncated.");
                    if (Kind(bytes, offset + 4, "acTL") || Kind(bytes, offset + 4, "fcTL"))
                        throw Invalid("Use a still PNG image with only one QR code.");
                    if (Kind(bytes, offset + 4, "eXIf")) result.Orientation = ExifOrientation(bytes, offset + 8, (int)size);
                    if (Kind(bytes, offset + 4, "IEND"))
                    {
                        if (size != 0 || offset + 12 != bytes.Length) throw Invalid("The PNG image has unexpected trailing data.");
                        ended = true; break;
                    }
                    offset += checked((int)size + 12);
                }
                if (!ended) throw Invalid("The PNG image is incomplete.");
            }
            else if (bytes.Length >= 4 && bytes[0] == 255 && bytes[1] == 216)
            {
                int offset = 2; bool dimensions = false;
                while (offset < bytes.Length)
                {
                    if (bytes[offset++] != 255) throw Invalid("The JPEG header is invalid.");
                    while (offset < bytes.Length && bytes[offset] == 255) offset++;
                    if (offset >= bytes.Length) throw Invalid("The JPEG image is truncated.");
                    int marker = bytes[offset++];
                    if (marker == 0xDA || marker == 0xD9) break;
                    if (marker == 0 || marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7)) throw Invalid("The JPEG header is invalid.");
                    if (offset > bytes.Length - 2) throw Invalid("The JPEG image is truncated.");
                    int size = Big16(bytes, offset);
                    if (size < 2 || size > bytes.Length - offset) throw Invalid("The JPEG image is truncated.");
                    if (marker == 0xC0 || marker == 0xC1 || marker == 0xC2)
                    {
                        if (size < 8 || bytes[offset + 2] != 8 || dimensions) throw Invalid("The JPEG dimensions are invalid.");
                        result.Height = Big16(bytes, offset + 3); result.Width = Big16(bytes, offset + 5); dimensions = true;
                    }
                    if (marker == 0xE1 && size >= 8 && Kind(bytes, offset + 2, "Exif") && bytes[offset + 6] == 0 && bytes[offset + 7] == 0)
                        result.Orientation = ExifOrientation(bytes, offset + 8, size - 8);
                    offset += size;
                }
                if (!dimensions) throw Invalid("Use a standard JPEG image with dimensions in its header.");
            }
            else if (bytes.Length >= 54 && bytes[0] == 66 && bytes[1] == 77)
            {
                uint dibSize = Little32(bytes, 14);
                if (dibSize < 40 || dibSize > bytes.Length - 14 || Little32(bytes, 18) > Int32.MaxValue)
                    throw Invalid("Use a standard BMP image.");
                result.Width = (int)Little32(bytes, 18);
                int height = unchecked((int)Little32(bytes, 22));
                if (height == Int32.MinValue) throw Invalid("The BMP dimensions are invalid.");
                result.Height = Math.Abs(height);
            }
            else throw Invalid("Choose a PNG, JPEG or BMP QR image.");
            ValidateDimensions(result.Width, result.Height);
            return result;
        }

        private static int ExifOrientation(byte[] data, int start, int length)
        {
            if (length < 8 || start < 0 || start > data.Length - length) throw Invalid("The image orientation metadata is invalid.");
            bool little = data[start] == 73 && data[start + 1] == 73;
            if (!little && !(data[start] == 77 && data[start + 1] == 77)) throw Invalid("The image orientation metadata is invalid.");
            if (Exif16(data, start + 2, little) != 42) throw Invalid("The image orientation metadata is invalid.");
            uint relative = Exif32(data, start + 4, little);
            if (relative < 8 || relative > (uint)(length - 2)) throw Invalid("The image orientation metadata is invalid.");
            int offset = start + (int)relative; int count = Exif16(data, offset, little); offset += 2;
            if (count > 256 || count > (start + length - offset) / 12) throw Invalid("The image orientation metadata is invalid.");
            int orientation = 1; bool found = false;
            for (int i = 0; i < count; i++, offset += 12)
                if (Exif16(data, offset, little) == 0x112)
                {
                    if (found || Exif16(data, offset + 2, little) != 3 || Exif32(data, offset + 4, little) != 1)
                        throw Invalid("The image orientation metadata is invalid.");
                    orientation = Exif16(data, offset + 8, little); found = true;
                    if (orientation < 1 || orientation > 8) throw Invalid("The image orientation metadata is invalid.");
                }
            return orientation;
        }

        internal static byte[] Orient(byte[] input, int width, int height, int orientation, out int outputWidth, out int outputHeight)
        {
            ValidateDecodeDimensions(input, width, height);
            if (orientation < 1 || orientation > 8) throw Invalid("The image orientation metadata is invalid.");
            outputWidth = orientation >= 5 ? height : width; outputHeight = orientation >= 5 ? width : height;
            if (orientation == 1) return input;
            byte[] output = new byte[input.Length];
            for (int y = 0; y < height; y++)
                for (int x = 0; x < width; x++)
                {
                    int dx = x, dy = y;
                    switch (orientation)
                    {
                        case 2: dx = width - 1 - x; break;
                        case 3: dx = width - 1 - x; dy = height - 1 - y; break;
                        case 4: dy = height - 1 - y; break;
                        case 5: dx = y; dy = x; break;
                        case 6: dx = height - 1 - y; dy = x; break;
                        case 7: dx = height - 1 - y; dy = width - 1 - x; break;
                        case 8: dx = y; dy = width - 1 - x; break;
                    }
                    output[dy * outputWidth + dx] = input[y * width + x];
                }
            return output;
        }

        internal static string ReadLuminance(byte[] luminance, int width, int height)
        {
            ValidateDecodeDimensions(luminance, width, height);
            string answer = null; int decodedCount = 0;
            LuminanceSource source = new GraySource(luminance, width, height);
            for (int pass = 0; pass < 2; pass++)
            {
                int patternCount = 0;
                Dictionary<DecodeHintType, object> hints = new Dictionary<DecodeHintType, object>();
                hints[DecodeHintType.TRY_HARDER] = true;
                hints[DecodeHintType.CHARACTER_SET] = "UTF-8";
                hints[DecodeHintType.NEED_RESULT_POINT_CALLBACK] = new ResultPointCallback(delegate(ResultPoint point)
                {
                    if (++patternCount > MaxFinderPatterns) throw Invalid("The image is too complex. Crop it to a single QR code.");
                });
                BinaryBitmap binary = new BinaryBitmap(new HybridBinarizer(pass == 0 ? source : new InvertedLuminanceSource(source)));
                BitMatrix matrix = binary.BlackMatrix;
                if (matrix == null) continue;
                DetectorResult[] candidates = new MultiDetector(matrix).detectMulti(hints);
                if (candidates.Length > MaxDetectorCandidates) throw Invalid("The image is too complex. Crop it to a single QR code.");
                foreach (DetectorResult candidate in candidates)
                {
                    DecoderResult result = new Decoder().decode(candidate.Bits, hints);
                    if (result == null) continue;
                    if (++decodedCount > 1 || result.StructuredAppend)
                        throw Invalid("The image contains multiple QR codes. Crop it to just the Mac connection QR.");
                    answer = result.Text;
                }
            }
            if (decodedCount != 1 || String.IsNullOrEmpty(answer)) throw Invalid("No readable QR code was found. Choose a clearer image or crop it closer.");
            if (answer.Length > 2048) throw Invalid("The QR code is not a supported connection address.");
            foreach (char character in answer)
                if (character < 32 || character > 126) throw Invalid("The QR code is not a supported connection address.");
            return answer;
        }

        private static void ValidateDecodeDimensions(byte[] input, int width, int height)
        {
            if (input == null || width <= 0 || height <= 0 || width > MaxDecodeDimension || height > MaxDecodeDimension || (long)width * height != input.Length)
                throw Invalid("The QR decode buffer is outside its limits.");
        }

        private sealed class GraySource : LuminanceSource
        {
            private readonly byte[] pixels;
            internal GraySource(byte[] pixels, int width, int height) : base(width, height) { this.pixels = pixels; }
            public override byte[] Matrix { get { return pixels; } }
            public override byte[] getRow(int row, byte[] buffer)
            {
                if (row < 0 || row >= Height) throw new ArgumentOutOfRangeException("row");
                if (buffer == null || buffer.Length < Width) buffer = new byte[Width];
                Buffer.BlockCopy(pixels, row * Width, buffer, 0, Width); return buffer;
            }
        }

        private static bool Kind(byte[] data, int offset, string text)
        {
            if (offset < 0 || offset > data.Length - text.Length) return false;
            for (int i = 0; i < text.Length; i++) if (data[offset + i] != text[i]) return false;
            return true;
        }
        private static uint Big32(byte[] data, int offset) { return ((uint)data[offset] << 24) | ((uint)data[offset + 1] << 16) | ((uint)data[offset + 2] << 8) | data[offset + 3]; }
        private static uint Little32(byte[] data, int offset) { return data[offset] | ((uint)data[offset + 1] << 8) | ((uint)data[offset + 2] << 16) | ((uint)data[offset + 3] << 24); }
        private static int Big16(byte[] data, int offset) { return (data[offset] << 8) | data[offset + 1]; }
        private static int Exif16(byte[] data, int offset, bool little) { return little ? data[offset] | (data[offset + 1] << 8) : Big16(data, offset); }
        private static uint Exif32(byte[] data, int offset, bool little) { return little ? Little32(data, offset) : Big32(data, offset); }
        private static int Positive(uint value) { if (value == 0 || value > Int32.MaxValue) throw Invalid("The image dimensions are invalid."); return (int)value; }
        private static InvalidDataException Invalid(string message) { return new InvalidDataException(message); }
    }
}
