(window.webpackJsonp = window.webpackJsonp || []).push([
  ["organization/download/version"],
  {
    fixture: function () {
      var z = function (e, t) {
        var n = {
          "0.53.99": {
            time: "2024/10/24",
            name: "Cangjie 0.53.99",
            version: "0.53.99",
            versiontype: "STS",
            list: [
              {
                name: "",
                list: [
                  {
                    name: "Windows",
                    list: [
                      {
                        name: "Cangjie-0.53.99-windows_x64.zip",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=Cangjie-0.53.99-windows_x64.zip&objectKey=legacyWindows001",
                        version: "0.53.99",
                        time: "2024-10-24",
                        sha: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                        size: "328.84MB"
                      }
                    ]
                  },
                  {
                    name: "Mac",
                    list: [
                      {
                        name: "Cangjie-0.53.99-darwin_aarch64.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=Cangjie-0.53.99-darwin_aarch64.tar.gz&objectKey=legacyMacArm001",
                        version: "0.53.99",
                        time: "2024-10-24",
                        sha: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
                        size: "169.46MB"
                      }
                    ]
                  },
                  {
                    name: "Linux",
                    list: [
                      {
                        name: "Cangjie-0.53.99-linux_x64.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=Cangjie-0.53.99-linux_x64.tar.gz&objectKey=legacyLinux001",
                        version: "0.53.99",
                        time: "2024-10-24",
                        sha: "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
                        size: "180.00MB"
                      }
                    ]
                  }
                ]
              },
              {
                name: t("page.down.tools"),
                list: [
                  {
                    name: "VScode Plugin",
                    list: [
                      {
                        name: "Cangjie-vscode-0.53.99.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=Cangjie-vscode-0.53.99.tar.gz&objectKey=ignoredVscode001",
                        version: "0.53.99",
                        time: "2024-10-24",
                        sha: "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
                        size: "4.0MB"
                      }
                    ]
                  }
                ]
              }
            ]
          },
          "2.0.0-beta.1": {
            time: "2027/01/02",
            name: "Cangjie 2.0.0-beta.1",
            version: "2.0.0-beta.1",
            versiontype: "LTS",
            docurl: "/docs?url=" + encodeURIComponent("https://example.invalid/docs"),
            list: [
              {
                name: "",
                list: [
                  {
                    name: "Windows",
                    list: [
                      {
                        name: "cangjie-sdk-windows-x64-2.0.0-beta.1.exe",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-windows-x64-2.0.0-beta.1.exe&objectKey=modernWindowsExe01",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "1111111111111111111111111111111111111111111111111111111111111111",
                        size: "127.38MB"
                      },
                      {
                        name: "cangjie-sdk-windows-x64-2.0.0-beta.1.zip",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-windows-x64-2.0.0-beta.1.zip&objectKey=modernWindowsZip01",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "2222222222222222222222222222222222222222222222222222222222222222",
                        size: "373.96MB"
                      }
                    ]
                  },
                  {
                    name: "Mac",
                    list: [
                      {
                        name: "cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-mac-aarch64-ios-2.0.0-beta.1.tar.gz&objectKey=modernMacIos0001",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "3333333333333333333333333333333333333333333333333333333333333333",
                        size: "350.3MB"
                      }
                    ]
                  },
                  {
                    name: "Linux",
                    list: [
                      {
                        name: "cangjie-sdk-linux-x64-android-arm32-2.0.0-beta.1.tar.gz",
                        url: "/v1/files/auth/downLoad?nsId=142267&fileName=cangjie-sdk-linux-x64-android-arm32-2.0.0-beta.1.tar.gz&objectKey=modernLinuxArm001",
                        version: "2.0.0-beta.1",
                        time: "2027-01-02",
                        sha: "4444444444444444444444444444444444444444444444444444444444444444",
                        size: "413.4MB"
                      }
                    ]
                  }
                ]
              }
            ]
          }
        };
        return M(M({}, n[e] || { list: [] }), {}, { all: Object.values(n).reverse() });
      };
    }
  }
]);
