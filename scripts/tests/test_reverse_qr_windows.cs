// SPDX-License-Identifier: GPL-3.0-only
// Windows-only acceptance fixture: all images are generated within its own temp directory.
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using DeskBridge.Reverse;
using Net.Codecrete.QrCodeGenerator;
using Graphics = System.Drawing.Graphics;

internal static class ReverseQrWindowsChecks
{
    private const string Link = "deskbridge://connect?v=1&name=Synthetic%20Mac&address=192.168.50.20";
    private static int checks;
    private static void Check(bool value, string name) { if (!value) throw new Exception("FAIL: " + name); checks++; }
    private static void Reject(Action action, string name)
    {
        try { action(); } catch (InvalidDataException) { checks++; return; }
        throw new Exception("FAIL: accepted " + name);
    }
    private static Bitmap Image(string text, bool transparent)
    {
        QrCode code = QrCode.EncodeText(text, QrCode.Ecc.Low); int side = (code.Size + 8) * 6;
        Bitmap bitmap = new Bitmap(side, side, PixelFormat.Format32bppArgb);
        for (int y = 0; y < side; y++) for (int x = 0; x < side; x++)
        {
            bool black = code.GetModule(x / 6 - 4, y / 6 - 4);
            bitmap.SetPixel(x,y,black?Color.Black:(transparent?Color.FromArgb(0,0,0,0):Color.White));
        }
        return bitmap;
    }
    private static byte[] ExifJpeg(byte[] jpeg, int orientation)
    {
        byte[] exif = {255,225,0,34,69,120,105,102,0,0,73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,(byte)orientation,0,0,0,0,0,0,0};
        return jpeg.Take(2).Concat(exif).Concat(jpeg.Skip(2)).ToArray();
    }
    private static int Main()
    {
        if (Environment.OSVersion.Platform != PlatformID.Win32NT) throw new PlatformNotSupportedException("Windows image-codec checks require Windows.");
        Check(!File.Exists(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "DeskBridge.QrDecoder.dll")), "no adjacent decoder DLL");
        ReverseQrLibrary.Initialize();
        const string identity = "DeskBridge.QrDecoder, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null";
        MethodInfo resolve = typeof(ReverseQrLibrary).GetMethod("Resolve", BindingFlags.Static | BindingFlags.NonPublic);
        Assembly decoder = (Assembly)resolve.Invoke(null, new object[] { null, new ResolveEventArgs(identity, Assembly.GetExecutingAssembly()) });
        Check(decoder != null && decoder.FullName == identity, "exact embedded decoder identity");
        ReverseQrLibrary.Initialize();
        Check(Object.ReferenceEquals(decoder, resolve.Invoke(null, new object[] { null, new ResolveEventArgs(identity, Assembly.GetExecutingAssembly()) })), "idempotent embedded decoder initialization");
        foreach (string other in new[] { "DeskBridge.QrDecoder, Version=1.0.0.0, Culture=neutral, PublicKeyToken=null", "Other.Decoder, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null" })
            Check(resolve.Invoke(null, new object[] { null, new ResolveEventArgs(other, Assembly.GetExecutingAssembly()) }) == null, "reject different decoder identity");
        string decoderSha256;
        using (Stream embedded = Assembly.GetExecutingAssembly().GetManifestResourceStream("DeskBridge.Reverse.QrDecoder"))
        using (SHA256 hash = SHA256.Create()) decoderSha256 = BitConverter.ToString(hash.ComputeHash(embedded)).Replace("-", "").ToLowerInvariant();
        string root = Path.Combine(Path.GetTempPath(), "deskbridge-reverse-qr-native-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            using (Bitmap image = Image(Link,false))
            {
                foreach (ImageFormat format in new[] {ImageFormat.Png,ImageFormat.Bmp,ImageFormat.Jpeg})
                {
                    string path = Path.Combine(root, format.ToString()+".img"); image.Save(path,format);
                    Check(ReverseQrReader.Read(path)==Link,"actual local "+format+" file");
                    // Read must close both its input stream and all native image objects.
                    using(FileStream exclusive=new FileStream(path,FileMode.Open,FileAccess.ReadWrite,FileShare.None)) Check(exclusive.Length>0,"released "+format+" file");
                }
                string jpg=Path.Combine(root,"Jpeg.img"); byte[] original=File.ReadAllBytes(jpg);
                for(int orientation=1;orientation<=8;orientation++)
                {
                    string path=Path.Combine(root,"oriented-"+orientation+".jpg");File.WriteAllBytes(path,ExifJpeg(original,orientation));
                    Check(ReverseQrReader.Read(path)==Link,"native JPEG EXIF "+orientation);
                }
                using(Bitmap pair=new Bitmap(image.Width*2+80,image.Height+40))
                {
                    using(Graphics graphics=Graphics.FromImage(pair))
                    { graphics.Clear(Color.White);graphics.DrawImageUnscaled(image,20,20);graphics.DrawImageUnscaled(image,image.Width+60,20); }
                    string path=Path.Combine(root,"multiple.png");pair.Save(path,ImageFormat.Png);
                    Reject(()=>ReverseQrReader.Read(path),"actual multiple PNG QR codes");
                }
            }
            using(Bitmap transparent=Image(Link,true))
            {
                string path=Path.Combine(root,"transparent.png");transparent.Save(path,ImageFormat.Png);
                Check(ReverseQrReader.Read(path)==Link,"transparent PNG composited against white");
            }
            string malformed=Path.Combine(root,"malformed.png");File.WriteAllBytes(malformed,new byte[]{137,80,78,71,13,10,26,10});
            Reject(()=>ReverseQrReader.Read(malformed),"actual malformed image file");
            string large=Path.Combine(root,"too-large.png");using(FileStream file=File.Create(large))file.SetLength(8L*1024*1024+1);
            Reject(()=>ReverseQrReader.Read(large),"actual encoded-file bound");
            string empty=Path.Combine(root,"empty.png");File.WriteAllBytes(empty,new byte[0]);
            Reject(()=>ReverseQrReader.Read(empty),"actual empty file");
            Reject(()=>ReverseQrReader.Read("\\\\localhost\\share\\qr.png"),"UNC path refused before opening");
            Check(Directory.GetFiles(root).Length==16,"fixture inventory only");
            Console.WriteLine("{\"status\":\"PASS\",\"checks\":"+checks+",\"windowsImageCodecTested\":true,\"freshSyntheticOnly\":true,\"embeddedDecoderBindingTested\":true,\"embeddedDecoderSha256\":\""+decoderSha256+"\"}");return 0;
        }
        finally { Directory.Delete(root,true); }
    }
}
