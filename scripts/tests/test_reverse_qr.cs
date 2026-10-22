// SPDX-License-Identifier: GPL-3.0-only
// Synthetic-only checks. No image files, clipboard, camera, GUI, or network.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using DeskBridge.Reverse;
using Net.Codecrete.QrCodeGenerator;

internal static class ReverseQrChecks
{
    private static int checks;
    private const string Link = "deskbridge://connect?v=1&name=Synthetic%20Mac&address=192.168.50.20";
    private static void Check(bool condition, string name) { if (!condition) throw new Exception("FAIL: " + name); checks++; }
    private static void Reject(Action action, string name)
    {
        try { action(); } catch (InvalidDataException) { checks++; return; }
        throw new Exception("FAIL: accepted " + name);
    }
    private static void RejectMessage(Action action, string text, string name)
    {
        try { action(); }
        catch (InvalidDataException error) { Check(error.Message.Contains(text), name + " precise error"); return; }
        throw new Exception("FAIL: accepted " + name);
    }
    private static byte[] Qr(string text, out int side)
    {
        QrCode qr = QrCode.EncodeText(text, QrCode.Ecc.Low); const int scale = 5, quiet = 4;
        side = (qr.Size + quiet * 2) * scale;
        byte[] pixels = Enumerable.Repeat((byte)255, side * side).ToArray();
        for (int y = 0; y < qr.Size; y++) for (int x = 0; x < qr.Size; x++)
            if (qr.GetModule(x, y))
                for (int dy = 0; dy < scale; dy++) for (int dx = 0; dx < scale; dx++)
                    pixels[((y + quiet) * scale + dy) * side + (x + quiet) * scale + dx] = 0;
        return pixels;
    }
    private static byte[] Pair(byte[] left, int leftSide, byte[] right, int rightSide, out int width, out int height)
    {
        width = leftSide + rightSide + 80; height = Math.Max(leftSide, rightSide) + 40;
        byte[] result = Enumerable.Repeat((byte)255, width * height).ToArray();
        for (int y = 0; y < leftSide; y++) Buffer.BlockCopy(left, y * leftSide, result, (y + 20) * width + 20, leftSide);
        for (int y = 0; y < rightSide; y++) Buffer.BlockCopy(right, y * rightSide, result, (y + 20) * width + leftSide + 60, rightSide);
        return result;
    }
    private static void Big32(List<byte> bytes, int value) { bytes.AddRange(new byte[] { (byte)(value >> 24), (byte)(value >> 16), (byte)(value >> 8), (byte)value }); }
    private static void Chunk(List<byte> bytes, string kind, byte[] content)
    {
        Big32(bytes, content.Length); bytes.AddRange(System.Text.Encoding.ASCII.GetBytes(kind)); bytes.AddRange(content); Big32(bytes, 0);
    }
    private static byte[] Exif(int orientation, bool little)
    {
        if (little) return new byte[] { 73,73,42,0,8,0,0,0,1,0,18,1,3,0,1,0,0,0,(byte)orientation,0,0,0,0,0,0,0 };
        return new byte[] { 77,77,0,42,0,0,0,8,0,1,1,18,0,3,0,0,0,1,0,(byte)orientation,0,0,0,0,0,0 };
    }
    private static byte[] PngHeader(int width, int height, byte[] exif, bool animated)
    {
        List<byte> bytes = new List<byte>(new byte[] {137,80,78,71,13,10,26,10}); List<byte> ihdr = new List<byte>();
        Big32(ihdr, width); Big32(ihdr, height); ihdr.AddRange(new byte[] {8,2,0,0,0}); Chunk(bytes,"IHDR",ihdr.ToArray());
        if (exif != null) Chunk(bytes,"eXIf",exif); if (animated) Chunk(bytes,"acTL",new byte[8]);
        Chunk(bytes,"IEND",new byte[0]); return bytes.ToArray();
    }
    private static byte[] JpegHeader(int orientation, bool little)
    {
        List<byte> bytes = new List<byte>(new byte[] {255,216,255,225}); byte[] exif = Exif(orientation,little);
        int length = exif.Length + 8; bytes.Add((byte)(length >> 8)); bytes.Add((byte)length); bytes.AddRange(new byte[] {69,120,105,102,0,0}); bytes.AddRange(exif);
        bytes.AddRange(new byte[] {255,192,0,17,8,0,120,0,160,3,1,17,0,2,17,0,3,17,0,255,218}); return bytes.ToArray();
    }
    private static byte[] BmpHeader(int width, int height)
    {
        byte[] bytes = new byte[54]; bytes[0]=66; bytes[1]=77; bytes[14]=40;
        Buffer.BlockCopy(BitConverter.GetBytes(width),0,bytes,18,4); Buffer.BlockCopy(BitConverter.GetBytes(height),0,bytes,22,4); return bytes;
    }

    private static int Main()
    {
        int side; byte[] pixels = Qr(Link, out side);
        Check(ReverseQrReader.ReadLuminance(pixels,side,side)==Link,"independent Nayuki generator interoperability");
        byte[][] expectations = {
            new byte[] {1,2,3,4,5,6}, new byte[] {3,2,1,6,5,4}, new byte[] {6,5,4,3,2,1}, new byte[] {4,5,6,1,2,3},
            new byte[] {1,4,2,5,3,6}, new byte[] {4,1,5,2,6,3}, new byte[] {6,3,5,2,4,1}, new byte[] {3,6,2,5,1,4}
        };
        for (int orientation = 1; orientation <= 8; orientation++)
        {
            int width,height; byte[] oriented = ReverseQrReader.Orient(new byte[] {1,2,3,4,5,6},3,2,orientation,out width,out height);
            Check(oriented.SequenceEqual(expectations[orientation-1]) && width==(orientation>=5?2:3) && height==(orientation>=5?3:2),"EXIF asymmetric transform "+orientation);
            oriented=ReverseQrReader.Orient(pixels,side,side,orientation,out width,out height);
            Check(ReverseQrReader.ReadLuminance(oriented,width,height)==Link,"actual QR rotated/mirrored decode "+orientation);
            Check(ReverseQrReader.InspectImage(JpegHeader(orientation,orientation%2==0)).Orientation==orientation,"JPEG TIFF endian EXIF "+orientation);
            Check(ReverseQrReader.InspectImage(PngHeader(160,120,Exif(orientation,orientation%2!=0),false)).Orientation==orientation,"PNG endian EXIF "+orientation);
        }
        byte[] inverted=pixels.Select(b=>(byte)(255-b)).ToArray();
        Check(ReverseQrReader.ReadLuminance(inverted,side,side)==Link,"inverted QR");
        int side2; byte[] second=Qr("deskbridge://connect?v=1&name=Other%20Mac&address=100.90.0.20",out side2); int pairWidth,pairHeight;
        byte[] pair=Pair(pixels,side,second,side2,out pairWidth,out pairHeight);
        RejectMessage(()=>ReverseQrReader.ReadLuminance(pair,pairWidth,pairHeight),"multiple QR codes","multiple distinct QR codes");
        pair=Pair(pixels,side,pixels,side,out pairWidth,out pairHeight);
        RejectMessage(()=>ReverseQrReader.ReadLuminance(pair,pairWidth,pairHeight),"multiple QR codes","multiple identical QR codes");
        pair=Pair(pixels,side,inverted,side,out pairWidth,out pairHeight);
        RejectMessage(()=>ReverseQrReader.ReadLuminance(pair,pairWidth,pairHeight),"multiple QR codes","mixed-polarity QR codes");
        Reject(()=>ReverseQrReader.ReadLuminance(new byte[40000],200,200),"blank black");
        Reject(()=>ReverseQrReader.ReadLuminance(Enumerable.Repeat((byte)255,40000).ToArray(),200,200),"blank white");
        byte[] busy=Enumerable.Repeat((byte)255,400*400).ToArray();
        for(int gy=0;gy<5;gy++) for(int gx=0;gx<5;gx++) for(int y=0;y<35;y++) for(int x=0;x<35;x++)
        { int mx=x/5,my=y/5; if(mx==0||my==0||mx==6||my==6||(mx>=2&&mx<=4&&my>=2&&my<=4))busy[(gy*75+y+20)*400+gx*75+x+20]=0; }
        RejectMessage(()=>ReverseQrReader.ReadLuminance(busy,400,400),"too complex","bounded finder-pattern flood");
        int textSide;byte[] nonAscii=Qr("deskbridge://connect?v=1&name=한글&address=192.168.50.20",out textSide);
        Reject(()=>ReverseQrReader.ReadLuminance(nonAscii,textSide,textSide),"non-ASCII payload");
        byte[] controls=Qr("deskbridge://connect?v=1&name=Mac&address=192.168.1.2\n",out textSide);
        Reject(()=>ReverseQrReader.ReadLuminance(controls,textSide,textSide),"control character payload");
        byte[] tooLong=Qr(new string('A',2049),out textSide);
        Reject(()=>ReverseQrReader.ReadLuminance(tooLong,textSide,textSide),"oversized decoded payload");
        Reject(()=>ReverseQrReader.ReadLuminance(null,1,1),"null decode buffer");
        Reject(()=>ReverseQrReader.ReadLuminance(new byte[10],3,3),"inconsistent decode buffer");
        Reject(()=>ReverseQrReader.ReadLuminance(new byte[2049],2049,1),"oversized decode edge");
        Reject(()=>ReverseQrReader.ValidateFileLength(0),"empty image");
        ReverseQrReader.ValidateFileLength(8*1024*1024);checks++;
        Reject(()=>ReverseQrReader.ValidateFileLength(8L*1024*1024+1),"encoded file size");
        ReverseQrReader.ValidateDimensions(4000,4000);checks++;
        Reject(()=>ReverseQrReader.ValidateDimensions(4001,4000),"16MP image pixel bound");
        Reject(()=>ReverseQrReader.ValidateDimensions(16385,1),"image dimension bound");
        Check(ReverseQrReader.InspectImage(PngHeader(160,120,null,false)).Width==160,"PNG dimensions");
        Check(ReverseQrReader.InspectImage(BmpHeader(160,-120)).Height==120,"top-down BMP dimensions");
        Check(ReverseQrReader.InspectImage(JpegHeader(1,true)).Height==120,"JPEG dimensions");
        Reject(()=>ReverseQrReader.InspectImage(PngHeader(4001,4000,null,false)),"PNG pixel bomb");
        Reject(()=>ReverseQrReader.InspectImage(BmpHeader(Int32.MaxValue,Int32.MaxValue)),"BMP pixel bomb");
        Reject(()=>ReverseQrReader.InspectImage(PngHeader(160,120,null,true)),"animated PNG");
        Reject(()=>ReverseQrReader.InspectImage(PngHeader(160,120,Exif(9,true),false)),"invalid EXIF orientation");
        byte[] trailing=PngHeader(160,120,null,false).Concat(new byte[]{0}).ToArray();
        Reject(()=>ReverseQrReader.InspectImage(trailing),"PNG trailing data");
        Reject(()=>ReverseQrReader.InspectImage(new byte[]{71,73,70,56,57,97}),"GIF refused");
        Reject(()=>ReverseQrReader.InspectImage(new byte[]{60,115,118,103,62}),"SVG refused");
        byte[] truncated=JpegHeader(1,true).Take(20).ToArray();Reject(()=>ReverseQrReader.InspectImage(truncated),"truncated JPEG");
        byte[] badExif=Exif(1,true);badExif[4]=255;badExif[5]=255;
        Reject(()=>ReverseQrReader.InspectImage(PngHeader(160,120,badExif,false)),"EXIF IFD out-of-bounds");
        int ow,oh;Reject(()=>ReverseQrReader.Orient(pixels,side,side,0,out ow,out oh),"invalid orientation transform");
        Console.WriteLine("{\"status\":\"PASS\",\"checks\":"+checks+",\"actualDecoder\":true,\"windowsImageCodecTested\":false}"); return 0;
    }
}
