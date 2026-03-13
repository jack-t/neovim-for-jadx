.class public Lcom/example/Hello;
.super Ljava/lang/Object;

.method public constructor <init>()V
    .registers 1
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public greet()Ljava/lang/String;
    .registers 2
    const-string v0, "Hello"
    return-object v0
.end method
