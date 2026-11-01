"""Host check of exact production helper; Android/JUnit APIs are explicit local doubles.

Requires Linux, Python 3, Java and kotlinc. Does NOT run Android native recovery,
Ktor authentication, AccountTransitionEvidence, Compose, Gradle or a signed build.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
SOURCES = {
    "org/junit/Test.java": 'package org.junit; @java.lang.annotation.Retention(java.lang.annotation.RetentionPolicy.RUNTIME) public @interface Test {}',
    "org/junit/Before.java": 'package org.junit; @java.lang.annotation.Retention(java.lang.annotation.RetentionPolicy.RUNTIME) public @interface Before {}',
    "org/junit/After.java": 'package org.junit; @java.lang.annotation.Retention(java.lang.annotation.RetentionPolicy.RUNTIME) public @interface After {}',
    "org/junit/Assert.java": '''package org.junit; public class Assert {
      public static void assertTrue(boolean v){if(!v)throw new AssertionError("expected true");}
      public static void assertFalse(boolean v){if(v)throw new AssertionError("expected false");}
      public static void assertEquals(Object a,Object b){if(!java.util.Objects.equals(a,b))throw new AssertionError("not equal: "+a+" / "+b);}
      public static void assertArrayEquals(byte[] a,byte[] b){if(!java.util.Arrays.equals(a,b))throw new AssertionError("bytes changed");}
    }''',
    "org/junit/runner/RunWith.java": 'package org.junit.runner; public @interface RunWith { Class<?> value(); }',
    "androidx/test/ext/junit/runners/AndroidJUnit4.java": 'package androidx.test.ext.junit.runners; public class AndroidJUnit4 {}',
    "android/content/Context.java": '''package android.content; public class Context {
      public java.io.File getCacheDir(){java.io.File f=new java.io.File(System.getProperty("fixture.root"));f.mkdirs();return f;}
    }''',
    "androidx/test/platform/app/InstrumentationRegistry.java": '''package androidx.test.platform.app; public class InstrumentationRegistry {
      public static InstrumentationRegistry getInstrumentation(){return new InstrumentationRegistry();}
      public android.content.Context getTargetContext(){return new android.content.Context();}
    }''',
    "android/system/OsConstants.java": '''package android.system; public class OsConstants {
      public static boolean S_ISREG(int m){return (m&0170000)==0100000;}
      public static boolean S_ISDIR(int m){return (m&0170000)==0040000;}
      public static boolean S_ISLNK(int m){return (m&0170000)==0120000;}
    }''',
    "android/system/StructStat.java": '''package android.system; public class StructStat {
      public int st_mode,st_uid; public long st_nlink,st_dev,st_ino;
    }''',
    "android/system/Os.java": '''package android.system; import java.nio.file.*; import java.util.Map; public class Os {
      public static StructStat lstat(String name)throws Exception {
        Map<String,Object> a=Files.readAttributes(Path.of(name),"unix:mode,uid,nlink,dev,ino",LinkOption.NOFOLLOW_LINKS);
        StructStat s=new StructStat();s.st_mode=((Number)a.get("mode")).intValue();s.st_uid=((Number)a.get("uid")).intValue();
        s.st_nlink=((Number)a.get("nlink")).longValue();s.st_dev=((Number)a.get("dev")).longValue();s.st_ino=((Number)a.get("ino")).longValue();return s;
      }
      public static void symlink(String target,String link)throws Exception{Files.createSymbolicLink(Path.of(link),Path.of(target));}
      public static void link(String target,String link)throws Exception{Files.createLink(Path.of(link),Path.of(target));}
      public static String readlink(String link)throws Exception{return Files.readSymbolicLink(Path.of(link)).toString();}
      public static void mkfifo(String path,int mode)throws Exception {
        if(new ProcessBuilder("mkfifo","-m",Integer.toOctalString(mode),path).inheritIO().start().waitFor()!=0)throw new java.io.IOException("mkfifo failed");
      }
    }''',
    "HostRunner.java": '''public class HostRunner { public static void main(String[] args)throws Exception {
      int passed=0;
      for(String name:args){Class<?> c=Class.forName(name);java.lang.reflect.Method[] methods=c.getDeclaredMethods();
        java.util.Arrays.sort(methods,java.util.Comparator.comparing(java.lang.reflect.Method::getName));
        for(java.lang.reflect.Method test:methods)if(test.isAnnotationPresent(org.junit.Test.class)){
          Object instance=c.getConstructor().newInstance();
          try {
            for(java.lang.reflect.Method m:methods)if(m.isAnnotationPresent(org.junit.Before.class))m.invoke(instance);
            test.invoke(instance);System.out.println("PASS "+c.getSimpleName()+"."+test.getName());passed++;
          }catch(java.lang.reflect.InvocationTargetException e){throw new RuntimeException(name+"."+test.getName(),e.getCause());}
          finally{for(java.lang.reflect.Method m:methods)if(m.isAnnotationPresent(org.junit.After.class))m.invoke(instance);}
        }
      }
      System.out.println("HOST TOTAL: "+passed+" passed. Android/JUnit doubles; NOT native or account-recovery acceptance.");
    }}''',
}


def main():
    for tool in ("javac", "java", "kotlinc", "mkfifo"):
        if not shutil.which(tool):
            raise SystemExit(f"Missing required tool: {tool}")
    with tempfile.TemporaryDirectory(prefix="vinetrack-maps-runtime-host-") as directory:
        work = Path(directory)
        for name, text in SOURCES.items():
            path = work / "stubs" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        classes = work / "classes"
        classes.mkdir()
        subprocess.run(["javac", "-d", str(classes), *map(str, (work / "stubs").rglob("*.java"))], check=True)
        app = REPO / "android-vinetrack/app/src"
        kotlin_sources = [
            app / "main/java/com/rork/vinetrack/data/auth/GoogleMapsRuntimeFiles.kt",
            app / "test/java/com/rork/vinetrack/data/auth/GoogleMapsRuntimeFilesTest.kt",
            app / "androidTest/java/com/rork/vinetrack/data/auth/GoogleMapsRuntimeFilesAndroidTest.kt",
        ]
        subprocess.run(["kotlinc", *map(str, kotlin_sources), "-cp", str(classes), "-d", str(work / "kotlin")], check=True)
        library = Path(shutil.which("kotlinc")).resolve().parents[1] / "lib/kotlin-stdlib.jar"
        classpath = os.pathsep.join(map(str, [classes, work / "kotlin", library]))
        subprocess.run(["java", "-Dfixture.root=" + str(work / "fixture"), "-cp", classpath, "HostRunner",
                        "com.rork.vinetrack.data.auth.GoogleMapsRuntimeFilesTest",
                        "com.rork.vinetrack.data.auth.GoogleMapsRuntimeFilesAndroidTest"], check=True)


if __name__ == "__main__":
    main()
