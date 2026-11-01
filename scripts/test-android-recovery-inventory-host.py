from pathlib import Path
import subprocess, os, shutil, tempfile
# Host-only Android/JUnit API doubles. Never a native Android or Gradle test run.
_temporary = tempfile.TemporaryDirectory(prefix="vinetrack-inventory-host-")
w=Path(_temporary.name)
repo=Path(__file__).resolve().parents[1]
sources={
'org/junit/Test.java':'package org.junit; @java.lang.annotation.Retention(java.lang.annotation.RetentionPolicy.RUNTIME) public @interface Test {}',
'org/junit/Before.java':'package org.junit; @java.lang.annotation.Retention(java.lang.annotation.RetentionPolicy.RUNTIME) public @interface Before {}',
'org/junit/After.java':'package org.junit; @java.lang.annotation.Retention(java.lang.annotation.RetentionPolicy.RUNTIME) public @interface After {}',
'org/junit/Assert.java':'''package org.junit;
public class Assert {
 public static void assertTrue(boolean x){if(!x)throw new AssertionError("expected true");}
 public static void assertFalse(boolean x){if(x)throw new AssertionError("expected false");}
 public static void assertEquals(Object a,Object b){if(!java.util.Objects.equals(a,b))throw new AssertionError("Expected "+a+" but got "+b);}
 public static void assertArrayEquals(byte[] a,byte[] b){if(!java.util.Arrays.equals(a,b))throw new AssertionError("bytes differ");}
}''',
'org/junit/runner/RunWith.java':'package org.junit.runner; public @interface RunWith { Class<?> value(); }',
'androidx/test/ext/junit/runners/AndroidJUnit4.java':'package androidx.test.ext.junit.runners; public class AndroidJUnit4 {}',
'android/content/pm/ApplicationInfo.java':'''package android.content.pm; public class ApplicationInfo {
 public String dataDir; public ApplicationInfo(){} public ApplicationInfo(ApplicationInfo a){dataDir=a.dataDir;}
}''',
'android/content/Context.java':'''package android.content;
public abstract class Context { public abstract java.io.File getFilesDir(); public abstract java.io.File getCacheDir(); public abstract android.content.pm.ApplicationInfo getApplicationInfo(); }
''',
'android/content/ContextWrapper.java':'''package android.content; public class ContextWrapper extends Context {
 private Context base; public ContextWrapper(Context b){base=b;}
 public java.io.File getFilesDir(){return base.getFilesDir();} public java.io.File getCacheDir(){return base.getCacheDir();}
 public android.content.pm.ApplicationInfo getApplicationInfo(){return base.getApplicationInfo();}
}''',
'androidx/test/platform/app/InstrumentationRegistry.java':'''package androidx.test.platform.app;
public class InstrumentationRegistry {
 public static StubInstrumentation getInstrumentation(){return new StubInstrumentation();}
 public static class StubInstrumentation { public android.content.Context getTargetContext(){
  return new android.content.Context(){
   java.io.File root=new java.io.File(System.getProperty("fixture.root"));
   public java.io.File getFilesDir(){java.io.File f=new java.io.File(root,"files");f.mkdirs();return f;}
   public java.io.File getCacheDir(){java.io.File f=new java.io.File(root,"cache");f.mkdirs();return f;}
   public android.content.pm.ApplicationInfo getApplicationInfo(){android.content.pm.ApplicationInfo i=new android.content.pm.ApplicationInfo();i.dataDir=root.getPath();return i;}
  }; }
 }
}''',
'com/rork/vinetrack/BuildConfig.java':'package com.rork.vinetrack; public class BuildConfig { public static final String VERSION_NAME="host-double"; public static final int VERSION_CODE=1; }',
'android/system/OsConstants.java':'''package android.system; public class OsConstants {
 public static final int ENOENT=2; public static boolean S_ISLNK(int m){return (m&0170000)==0120000;}
 public static boolean S_ISDIR(int m){return (m&0170000)==0040000;} public static boolean S_ISREG(int m){return (m&0170000)==0100000;}
}''',
'android/system/ErrnoException.java':'package android.system; public class ErrnoException extends Exception { public final int errno; public ErrnoException(int e){errno=e;} }',
'android/system/StructStat.java':'package android.system; public class StructStat { public int st_mode; public long st_size; public long st_nlink; }',
'android/system/Os.java':'''package android.system; import java.nio.file.*; import java.nio.file.attribute.*;
public class Os {
 public static StructStat lstat(String name)throws ErrnoException {try {
  Path p=Path.of(name); BasicFileAttributes a=Files.readAttributes(p,BasicFileAttributes.class,LinkOption.NOFOLLOW_LINKS);
  StructStat s=new StructStat();s.st_mode=a.isSymbolicLink()?0120000:a.isDirectory()?0040000:a.isRegularFile()?0100000:0;
  s.st_size=a.size();s.st_nlink=((Number)Files.getAttribute(p,"unix:nlink",LinkOption.NOFOLLOW_LINKS)).longValue();return s;
 }catch(NoSuchFileException e){throw new ErrnoException(2);}catch(Exception e){throw new ErrnoException(5);}}
 public static void symlink(String target,String link)throws Exception{Files.createSymbolicLink(Path.of(link),Path.of(target));}
 public static void link(String target,String link)throws Exception{Files.createLink(Path.of(link),Path.of(target));}
 public static String readlink(String link)throws Exception{return Files.readSymbolicLink(Path.of(link)).toString();}
}''',
'HostRunner.java':'''public class HostRunner {
 public static void main(String[] args)throws Exception {
 int passed=0;
 for(String name:args){Class<?> c=Class.forName(name);
  java.lang.reflect.Method[] methods=c.getDeclaredMethods(); java.util.Arrays.sort(methods,java.util.Comparator.comparing(java.lang.reflect.Method::getName));
  for(java.lang.reflect.Method test:methods)if(test.isAnnotationPresent(org.junit.Test.class)){
   Object instance=c.getConstructor().newInstance();
   try {for(java.lang.reflect.Method m:methods)if(m.isAnnotationPresent(org.junit.Before.class))m.invoke(instance);
    test.invoke(instance);System.out.println("PASS "+c.getSimpleName()+"."+test.getName());passed++;
   }catch(java.lang.reflect.InvocationTargetException e){throw new RuntimeException(name+"."+test.getName(),e.getCause());}
   finally{for(java.lang.reflect.Method m:methods)if(m.isAnnotationPresent(org.junit.After.class))m.invoke(instance);}
  }
 }
 System.out.println("HOST TOTAL: "+passed+" passed. Android APIs and JUnit runner are local doubles; NOT native/Gradle/device acceptance.");
 }
}'''
}
for name,content in sources.items():
 p=w/'stubs'/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content)
classes=w/'classes';classes.mkdir(exist_ok=True)
subprocess.run(['javac','-d',str(classes),*[str(p) for p in (w/'stubs').rglob('*.java')]],check=True)
root=repo/"android-vinetrack/app"
subprocess.run(['kotlinc',str(root/'src/main/java/com/rork/vinetrack/data/auth/RecoveryStorageReport.kt'),str(root/'src/main/java/com/rork/vinetrack/data/auth/RecoveryStorageInventory.kt'),str(root/'src/test/java/com/rork/vinetrack/data/auth/RecoveryStorageReportTest.kt'),str(root/'src/androidTest/java/com/rork/vinetrack/data/auth/RecoveryStorageInventoryAndroidTest.kt'),'-cp',str(classes),'-d',str(w/'kotlin-classes')],check=True)
kotlinlib=Path(shutil.which('kotlinc')).resolve().parents[1]/'lib'
fixture=w/'fixture';fixture.mkdir(exist_ok=True)
cp=os.pathsep.join([str(classes),str(w/'kotlin-classes'),str(kotlinlib/'kotlin-stdlib.jar')])
subprocess.run(['java','-Dfixture.root='+str(fixture),'-cp',cp,'HostRunner','com.rork.vinetrack.data.auth.RecoveryStorageReportTest','com.rork.vinetrack.data.auth.RecoveryStorageInventoryAndroidTest'],check=True)
